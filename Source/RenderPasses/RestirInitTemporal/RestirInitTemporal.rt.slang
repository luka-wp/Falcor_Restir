#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

cbuffer CB
{
    uint gFrameCount;
    bool gInitLights;
    bool gTemporalReuse;
    bool gIndirectLight;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector;

RWTexture2D<float4> gReservoirPrevious;
RWTexture2D<float4> gReservoirCurrent;
RWTexture2D<float4> gOutputColor;

struct ShadowRayPayload
{
    bool visible;
};

struct IndirectRayPayload
{
    float3 color;
    uint randomSeed;
    SampleGenerator sampleGenerator;

    // ray data
    float3 origin;
    float3 direction;

    __init(SampleGenerator sg)
    {
        this.color = float3(0.f);
        this.randomSeed = 0;
        this.sampleGenerator = sg;
        this.origin = float3(0.f);
        this.direction = float3(0.f);
    }
};

float4 updateReservoir(float4 reservoir, int lightToSample, float weight, SampleGenerator sampleGenerator) {
    // Algorithm 2 of ReSTIR paper
    reservoir.x = reservoir.x + weight; // r.w_sum
    reservoir.z = reservoir.z + 1.0f;   // r.M
    if (sampleNext1D(sampleGenerator) < weight / reservoir.x) {
        reservoir.y = lightToSample; // r.y
    }

    return reservoir;
}

#define is_valid(name) (is_valid_##name != 0)
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
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

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    ShadowRayPayload rayData;
    rayData.visible = false; // Set to true by miss shader if ray is not terminated before
    TraceRay(
        gScene.rtAccel,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        0xff /* instanceInclusionMask */,
        0 /* hitIdx */,
        rayTypeCount,
        0 /* missIdx */,
        ray,
        rayData
    );

    return rayData.visible;
}

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, inout int lightIdx, bool visibilityTest = true)
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

    // Test visibility by tracing a shadow ray.
    if (visibilityTest)
    {
        bool V = traceShadowRay(origin, ls.dir, ls.distance);
        if (!V)
            return float3(0.f);
    }
        
    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

/*  ============ *
    Entry Points
 *  ============ */

[shader("miss")]
void shadowMiss(inout ShadowRayPayload rayData)
{
    rayData.visible = true;
}

[shader("anyhit")]
void shadowAnyHit(inout ShadowRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
    {
        IgnoreHit();
    }
}

[shader("miss")]
void indirectMiss(inout IndirectRayPayload rayData)
{
    rayData.color = float3(0.f);
}

[shader("anyhit")]
void indirectAnyHit(inout IndirectRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
    {
        IgnoreHit();
    }
}

[shader("closesthit")]
void indirectClosestHit(inout IndirectRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    HitInfo hitInfo = HitInfo(triangleHit);
    let lod = ExplicitLodTextureSampler(0.f);

    ShadingData shadingData = loadShadingData(hitInfo, rayData.origin, rayData.direction, lod);
    IMaterialInstance materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);
    int lightIndex = -1;
    rayData.color = evalDirectAnalytic(shadingData, materialInstance, rayData.sampleGenerator, lightIndex);
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    const HitInfo hit = HitInfo(gVBuffer[launchIndex]);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(launchIndex, launchDim, gScene.camera);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData shadingData = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
    IMaterialInstance materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);

    float2 posH = float2(launchIndex) / float2(launchDim);

    float4 previousReservoir = float4(0.f);
    if (!gInitLights)
    {
        float2 posHPrev = posH + gMotionVector[launchIndex].xy;
        uint2 prevIndex = launchIndex;
        prevIndex.xy = int2(posHPrev * launchDim);
        if (prevIndex.x >= 0 && prevIndex.x < launchDim.x && prevIndex.y >= 0 && prevIndex.y < launchDim.y)
        {
            previousReservoir = gReservoirPrevious[prevIndex];
        }
    }

    SampleGenerator sampleGenerator = SampleGenerator(launchIndex, gFrameCount);
    float4 currentReservoir = float4(0.f);
    float pHat = 0.f;

    for (int i = 0; i < gScene.lightCount; i++)
    {
        int lightIndex = -1;
        pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
        currentReservoir = updateReservoir(currentReservoir, lightIndex, pHat, sampleGenerator);
    }

    int lightIndex = int(currentReservoir.y);
    pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, true));
    if (pHat == 0.f)
    {
        currentReservoir.w = 0.f;
    }
    else
    {
        currentReservoir.w = (1.f / max(pHat, 0.0001f)) * (currentReservoir.x / max(currentReservoir.z, 0.0001f));
    }

    if (gTemporalReuse)
    {
        float4 temporalReservoir = float4(0.f);
        temporalReservoir = updateReservoir(temporalReservoir, currentReservoir.y, pHat * currentReservoir.w * currentReservoir.z, sampleGenerator);
        
        lightIndex = int(previousReservoir.y);
        pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
        previousReservoir.z = min(20.0f * currentReservoir.z, previousReservoir.z);
        temporalReservoir = updateReservoir(temporalReservoir, previousReservoir.y, pHat * previousReservoir.w * previousReservoir.z, sampleGenerator);

        temporalReservoir.z = currentReservoir.z + previousReservoir.z;

        lightIndex = int(temporalReservoir.y);
        pHat = length(evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, false));
        temporalReservoir.w = (1.f / max(pHat, 0.0001f)) * (temporalReservoir.x / max(temporalReservoir.z, 0.0001f));

        currentReservoir = temporalReservoir;
    }

    if(gIndirectLight)
    {
        
    }

    gReservoirCurrent[launchIndex] = currentReservoir;
    gOutputColor[launchIndex] = float4(float3(currentReservoir.w), 1.0f);
}
