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
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

RWTexture2D<float4> gReservoirPrevious;
RWTexture2D<float4> gReservoirSpatial;

RWTexture2D<float4> gOutputColor;

struct ShadowRayPayload
{
    bool visible;
};

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

    float4 reservoir = gReservoirSpatial[pixelXY];
    gReservoirPrevious[pixelXY] = reservoir;

    SampleGenerator sampleGenerator = SampleGenerator(pixelXY, gFrameCount);

    int lightIndex = int(reservoir.y);
    float3 shadeColor = evalDirectAnalytic(shadingData, materialInstance, sampleGenerator, lightIndex, true);
    float3 outColor = shadeColor * reservoir.w;

    gOutputColor[pixelXY] = float4(outColor, 1.0f);
}