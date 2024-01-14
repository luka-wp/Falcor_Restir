#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;

/* ================ *
 * ==== Common ==== *
 * ==== Begin ===== *
 * ================ */

struct Reservoir
{
    float3 visiblePoint;
    float3 visibleNormal;

    float3 samplePoint;
    float3 sampleNormal;
    float3 sampleRadiance;

    float weightSum;
    uint M;
    uint age;

    static Reservoir makeReservoir(
        float3 inVisiblePoint,
        float3 inVisibleNormal,
        float3 inSamplePoint,
        float3 inSampleNormal,
        float3 inSampleRadiance,
        float inSamplePdf
    )
    {
        Reservoir reservoir;
        reservoir.visiblePoint = inVisiblePoint;
        reservoir.visibleNormal = inVisibleNormal;
        reservoir.samplePoint = inSamplePoint;
        reservoir.sampleNormal = inSampleNormal;
        reservoir.sampleRadiance = inSampleRadiance;
        reservoir.weightSum = inSamplePdf > 0.f ? 1.f / inSamplePdf : 0.f;
        reservoir.M = 1;
        reservoir.age = 0;
        return reservoir;
    }

    static Reservoir makeEmpty()
    {
        Reservoir reservoir;
        reservoir.visiblePoint = float3(0.f);
        reservoir.visibleNormal = float3(0.f);
        reservoir.samplePoint = float3(0.f);
        reservoir.sampleNormal = float3(0.f);
        reservoir.sampleRadiance = float3(0.f);
        reservoir.weightSum = 0.f;
        reservoir.M = 0;
        reservoir.age = 0;
        return reservoir;
    }

    bool isValid() { return M != 0; }

    [mutating]
    bool merge(Reservoir reservoir, float targetPdf, float random)
    {
        float risWeight = targetPdf * reservoir.weightSum * reservoir.M;
        M += reservoir.M;
        weightSum += risWeight;
        bool selectSample = (random * weightSum <= risWeight);
        if (selectSample)
        {
            samplePoint = reservoir.samplePoint;
            sampleNormal = reservoir.sampleNormal;
            sampleRadiance = reservoir.sampleRadiance;
            age = reservoir.age;
        }

        return selectSample;
    }

    [mutating]
    void finalize(float numerator, float denominator) { weightSum = (denominator == 0.f) ? 0.f : (weightSum * numerator) / denominator; }
};

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

#define is_valid(name) (is_valid_##name != 0)

void getShadingDataAndMaterial(out ShadingData shadingData, out IMaterialInstance materialInstance, uint2 pixel, uint2 frameDim)
{
    float3 rayDir = float3(0.f);
    { // Inlined getPrimaryRayDir
        if (is_valid(gViewW))
        {
            rayDir = -gViewW[pixel].xyz;
        }
        rayDir = gScene.camera.computeRayPinhole(pixel, frameDim).dir;
    }

    let lod = ExplicitLodTextureSampler(0.f);
    { // Inlined loadShadingData
        const HitInfo hit = HitInfo(gVBuffer[pixel]);
        VertexData v = {};
        uint materialID = {};
        if (hit.getType() == HitType::Triangle)
        {
            const TriangleHit triangleHit = hit.getTriangleHit();
            v = gScene.getVertexData(triangleHit);
            materialID = gScene.getMaterialID(triangleHit.instanceID);
        }

        shadingData = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    }

    { // Material instance
        materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);
    }
}

uint getPixelIndex(uint2 pixel, uint2 frame)
{
    return pixel.x + pixel.y * frame.x;
}

float getTargetPdfForSurface(ShadingData shadingData, IMaterialInstance materialInstance, float3 samplePosition, float3 sampleRadiance)
{
    float3 L = normalize(samplePosition - shadingData.posW);
    float NdotL = saturate(dot(L, shadingData.faceN));
    BSDFProperties bsdf = materialInstance.getProperties(shadingData);
    float3 reflectedRadiance = sampleRadiance * bsdf.diffuseReflectionAlbedo * NdotL;
    // float3 reflectedRadiance = sampleRadiance * (bsdf.diffuseReflectionAlbedo + bsdf.specularReflectionAlbedo);
    // return luminance(reflectedRadiance);
    return luminance(sampleRadiance);
}

void calculatePartialJacobian(
    const float3 reciverPos,
    const float3 samplePos,
    const float3 sampleNormal,
    out float distanceToSurface,
    out float cosineEmissionAngle
)
{
    float3 vec = reciverPos - samplePos;
    distanceToSurface = length(vec);
    cosineEmissionAngle = saturate(dot(sampleNormal, vec / distanceToSurface));
}

float calculateJacobian(float3 reciverPos, float3 neighborReciverPos, Reservoir neighborReservoir)
{
    float originalDistance, originalCosine;
    float newDistance, newCosine;
    calculatePartialJacobian(reciverPos, neighborReservoir.samplePoint, neighborReservoir.sampleNormal, newDistance, newCosine);
    calculatePartialJacobian(
        neighborReciverPos, neighborReservoir.samplePoint, neighborReservoir.sampleNormal, originalDistance, originalCosine
    );

    float jacobian = (newCosine * originalDistance * originalDistance) / (originalCosine * newDistance * newDistance);

    if (isinf(jacobian) || isnan(jacobian))
    {
        jacobian = 0.f;
    }
    return jacobian;
}

bool validateSampleWithJacobian(inout float jacobian)
{
    if (jacobian > 10.f || jacobian < 0.1f)
    {
        return false;
    }

    jacobian = clamp(jacobian, 1.f / 3.f, 3.f);
    return true;
}

/* ================ *
 * ==== Common ==== *
 * ==== End ===== *
 * ================ */

// float targetFunctionPDF(SceneSample inSample)
// {
//     // Simpler target function
//     return luminance(inSample.radiance);
// }

Texture2D<float4> gMotionVector;
RWStructuredBuffer<Reservoir> gTemporalReservoirOld;
RWStructuredBuffer<Reservoir> gTemporalReservoirNew;
RWStructuredBuffer<Reservoir> gCurrentReservoir;
RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gInitialSamples;

    bool gEnableTemporal;
}

static const uint kMaxM = 30;
static const uint kMaxAge = 100;

int2 temporalResamplingOffset(int sampleIdx, int radius)
{
    sampleIdx &= 7;

    int mask2 = sampleIdx >> 1 & 0x01;       // 0, 0, 1, 1, 0, 0, 1, 1
    int mask4 = 1 - (sampleIdx >> 2 & 0x01); // 1, 1, 1, 1, 0, 0, 0, 0
    int tmp0 = -1 + 2 * (sampleIdx & 0x01);  // -1, 1,....
    int tmp1 = 1 - 2 * mask2;                // 1, 1,-1,-1, 1, 1,-1,-1
    int tmp2 = mask4 | mask2;                // 1, 1, 1, 1, 0, 0, 1, 1
    int tmp3 = mask4 | (1 - mask2);          // 1, 1, 1, 1, 1, 1, 0, 0

    return int2(tmp0, tmp0 * tmp1) * int2(tmp2, tmp3) * radius;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    Reservoir inputReservoir = gCurrentReservoir[pixelIndex];

    ShadingData inputShadingData;
    IMaterialInstance inputMaterialInstance;
    getShadingDataAndMaterial(inputShadingData, inputMaterialInstance, pixel, frameDim);

    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    int2 prevPos = pixel + int2(gMotionVector[pixel].xy * frameDim);

    uint2 pixelPrev;
    Reservoir temporalReservoir;
    bool foundTemporalReservoir = false;

    const int temporalSampleStartIdx = int(sampleNext1D(sampleGenerator) * 8);
    const int radius = 1;
    const int temporalSampleCount = 5;
    const int sampleCount = temporalSampleCount + 1;
    for (int i = 0; i < sampleCount; ++i)
    {
        const bool isFirstSample = i == 0;
        const bool isFallbackSample = i == temporalSampleCount;

        int2 offset = int2(0, 0);
        if (isFallbackSample)
        {
            prevPos = pixel;
        }
        else if (!isFirstSample)
        {
            offset = temporalResamplingOffset(temporalSampleStartIdx + i, radius);
        }

        int2 idx = prevPos + offset;

        // TODO: Geometric similarity

        if (any(idx < 0) || any(idx >= frameDim))
        {
            continue;
        }

        uint idxIndex = getPixelIndex(idx, frameDim);
        temporalReservoir = gTemporalReservoirOld[idxIndex];

        if (!temporalReservoir.isValid())
        {
            continue;
        }

        foundTemporalReservoir = true;
        pixelPrev = idx;
        break;
    }

    Reservoir curReservoir = Reservoir::makeEmpty();

    float selectedTargetPdf = 0;
    if (inputReservoir.isValid())
    {
        selectedTargetPdf =
            getTargetPdfForSurface(inputShadingData, inputMaterialInstance, inputReservoir.samplePoint, inputReservoir.sampleRadiance);
        curReservoir.merge(inputReservoir, selectedTargetPdf, 0.5f);
    }

    if (foundTemporalReservoir)
    {
        float jacobian = calculateJacobian(inputReservoir.visiblePoint, temporalReservoir.visiblePoint, temporalReservoir);
        if (!validateSampleWithJacobian(jacobian))
        {
            foundTemporalReservoir = false;
        }

        temporalReservoir.weightSum *= jacobian;
        temporalReservoir.M = min(temporalReservoir.M, kMaxM);
        ++temporalReservoir.age;

        if (temporalReservoir.age > kMaxAge)
        {
            foundTemporalReservoir = false;
        }
    }

    bool selectedPreviousSample = false;
    if (foundTemporalReservoir)
    {
        ShadingData shadingData;
        IMaterialInstance materialInstance;
        getShadingDataAndMaterial(shadingData, materialInstance, pixelPrev, frameDim);
        float targetPdf =
            getTargetPdfForSurface(shadingData, inputMaterialInstance, temporalReservoir.samplePoint, temporalReservoir.sampleRadiance);
        selectedPreviousSample = curReservoir.merge(temporalReservoir, targetPdf, sampleNext1D(sampleGenerator));
        if (selectedPreviousSample)
        {
            selectedTargetPdf = targetPdf;
        }
    }

    float normalizationNumerator = 1.f;
    float normalizationDenominator = selectedTargetPdf * curReservoir.M;
    curReservoir.finalize(normalizationNumerator, normalizationDenominator);

    gTemporalReservoirNew[pixelIndex] = curReservoir;
}
