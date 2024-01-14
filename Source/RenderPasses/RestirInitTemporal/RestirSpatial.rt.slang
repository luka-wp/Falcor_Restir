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

    static Reservoir makeReservoir( float3 inVisiblePoint, float3 inVisibleNormal, float3 inSamplePoint, float3 inSampleNormal, float3 inSampleRadiance, float inSamplePdf )
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

/* ================ *
 * ==== Common ==== *
 * ==== End ===== *
 * ================ */

// float targetFunctionPDF(SceneSample inSample)
// {
//     // Simpler target function
//     return luminance(inSample.radiance);
// }

// float jacobianDeterminant(SceneSample qNeighbor, SceneSample rSource)
// {
//     float3 deltaQ = qNeighbor.visiblePoint - qNeighbor.samplePoint;
//     float3 deltaR = rSource.visiblePoint - qNeighbor.samplePoint;
//     float dq2 = dot(deltaQ, deltaQ);
//     float dr2 = dot(deltaR, deltaR);
//     float cosQ = dot(qNeighbor.sampleNormal, normalize(deltaQ));
//     float cosR = dot(qNeighbor.sampleNormal, normalize(deltaR));
//     float denum = cosQ * dr2;

//     if (denum <= 0.f)
//         return 0.f;

//     return (cosR * dq2) / denum;
// }

// Texture2D<PackedHitInfo> gVBuffer;
// Texture2D<float4> gViewW;

RWStructuredBuffer<Reservoir> gTemporalReservoir;
RWStructuredBuffer<Reservoir> gSpatialReservoir;
RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gEnableSpatial;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
   
    Reservoir temporalReservoir = gTemporalReservoir[pixelIndex];

    if (!gEnableSpatial)
    {
        gSpatialReservoir[pixelIndex] = temporalReservoir;
    }

    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);
    const uint numNeighbors = 5;
    const uint neighborSpan = 4;

    // uint Z = temporalReservoir.numStoredSamples_M;
    // for (int counter = 0; counter < numNeighbors; ++counter)
    // {
    //     int2 offset = int2(lerp(float2(-neighborSpan), float2(neighborSpan + 1), sampleNext2D(sampleGenerator)));
    //     int2 pixelNeighbor = pixel + offset;
    //     if (any(pixelNeighbor < 0) || any(pixelNeighbor >= frameDim) || all(offset == 0))
    //     {
    //         continue;
    //     }

    //     uint pixelNeighborIndex = getPixelIndex(pixelNeighbor, frameDim);
    //     Reservoir temporalReservoirNeighbor = gTemporalReservoir[pixelNeighborIndex];
    //     // TODO: Geometric similarity

    //     float jacobian = jacobianDeterminant(temporalReservoirNeighbor.sceneSample, temporalReservoir.sceneSample);
    //     float pHat = targetFunctionPDF(temporalReservoirNeighbor.sceneSample);
    //     float pHatP = 0.f;
    //     // TODO: Check if neighbor sample point is visible to destination visible point
    //     if (jacobian != 0.f)
    //     {
    //         pHatP = pHat / jacobian;
    //     }

    //     temporalReservoir.merge(temporalReservoirNeighbor, pHatP, sampleGenerator);
    //     Z += temporalReservoirNeighbor.numStoredSamples_M;
    // }

    // temporalReservoir.sceneSampleWeight_W =
    //     temporalReservoir.sampleRelativeWeight_w / (Z * targetFunctionPDF(temporalReservoir.sceneSample));

    gSpatialReservoir[pixelIndex] = temporalReservoir;
}
