#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

struct SceneSample
{
    float3 visiblePoint;
    float3 visibleNormal;
    float3 samplePoint;
    float3 sampleNormal;
    float3 Lo;
    __init()
    {
        visiblePoint = float3(0);
        visibleNormal = float3(0);
        samplePoint = float3(0);
        sampleNormal = float3(0);
        Lo = float3(0);
    }
}

struct Reservoir
{
    SceneSample sceneSample;
    float sampleRelativeWeight_w;
    uint numStoredSamples_M;
    float sceneSampleWeight_W;

    __init()
    {
        sceneSample = SceneSample();
        sampleRelativeWeight_w = 0.f;
        numStoredSamples_M = 0;
        sceneSampleWeight_W = 0.f;
    }

    [mutating] void update(SceneSample s, float weight, inout SampleGenerator sampleGenerator)
    {
        sampleRelativeWeight_w += weight;
        numStoredSamples_M += 1;
        if (sampleNext1D(sampleGenerator) < (weight / sampleRelativeWeight_w))
        {
            sceneSample = s;
        }
    }

    [mutating] void merge(Reservoir r, float pHat, inout SampleGenerator sampleGenerator)
    {
        uint M0 = numStoredSamples_M;
        update(r.sceneSample, pHat * r.sceneSampleWeight_W * r.numStoredSamples_M, sampleGenerator);
        numStoredSamples_M = M0 + r.numStoredSamples_M;
    }
};

cbuffer CB
{
    uint gFrameCount;
    bool gSpatialReuse;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

RWTexture2D<float4> gReservoirCurrent;
RWTexture2D<float4> gReservoirSpatial;

RWStructuredBuffer<Reservoir> gCurrentReservoir;
RWStructuredBuffer<Reservoir> gSpatialReservoir;

float4 updateReservoir(float4 reservoir, int lightToSample, float weight, SampleGenerator sampleGenerator) {
    reservoir.x = reservoir.x + weight; // r.w_sum
    reservoir.z = reservoir.z + 1.0f;   // r.M
    if (sampleNext1D(sampleGenerator) < weight / reservoir.x) {
        reservoir.y = lightToSample; // r.y
    }
    return reservoir;
}

#define is_valid(name) (is_valid_##name != 0)
float3 getPrimaryRayDir(uint2 pixelXY, uint2 frameDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[pixelXY].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(pixelXY, frameDim).dir;
    }
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData v = {};
    uint materialID = {};

    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

float3 evalDirectAnalytic( const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, inout int lightIdx, bool visibilityTest = true )
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = (lightIdx != -1) ? lightIdx : min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.
    lightIdx = lightIndex;

    // Sample local light source.
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float3(0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
    if ((NdotL <= kMinCosTheta && !hasTransmission) || (NdotL >= -kMinCosTheta && !hasReflection))
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixelXY = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    const HitInfo hit = HitInfo(gVBuffer[pixelXY]);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixelXY, frameDim, gScene.camera);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData shadingData = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
    IMaterialInstance materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);

    SampleGenerator sampleGenerator = SampleGenerator(pixelXY, gFrameCount);

    float pHat = 0.f;
    float4 newReservoir = float4(0.f);
    if (gSpatialReuse)
    {
        int neighborsCount = 15;
        int neighborsRange = 5;

        float4 currentReservoir = gReservoirCurrent[pixelXY];
        int lightIndex = int(currentReservoir.y);
        pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
        newReservoir = updateReservoir(newReservoir, currentReservoir.y, pHat * currentReservoir.w * currentReservoir.z, sampleGenerator);

        float samplesCount = currentReservoir.z;
        for (int i = 0; i < neighborsCount; ++i)
        {
            uint2 offset = int2(sampleNext2D(sampleGenerator) * neighborsRange.xx * 2) - neighborsRange.xx;
            uint2 neighborXY = max(uint2(0), min(frameDim - uint2(1), pixelXY + offset));

            float4 neighborReservoir = gReservoirCurrent[neighborXY];
            lightIndex = int(neighborReservoir.y);
            pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
            newReservoir = updateReservoir(newReservoir, neighborReservoir.y, pHat * neighborReservoir.w * neighborReservoir.z, sampleGenerator);
            samplesCount += neighborReservoir.z;
        }
        newReservoir.z = samplesCount;

        lightIndex = int(newReservoir.y);
        pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
        newReservoir.w = (1.f / max(pHat, 0.0001f)) * (newReservoir.x / max(newReservoir.z, 0.0001f));
    }
    else
    {
        newReservoir = gReservoirCurrent[pixelXY];
    }

    gReservoirSpatial[pixelXY] = newReservoir;
}