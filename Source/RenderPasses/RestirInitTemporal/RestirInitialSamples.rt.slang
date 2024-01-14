#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

static const uint kMaxBounces = 1;
static const bool kUseEmissiveLights = true;
static const bool kUseEnvLight = false;

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

    static Reservoir makeReservoir(float3 inVisiblePoint, float3 inVisibleNormal, float3 inSamplePoint, float3 inSampleNormal, float3 inSampleRadiance, float inSamplePdf)
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

/* ================ *
 * ==== Common ==== *
 * ==== End ===== *
 * ================ */

RWStructuredBuffer<Reservoir> gCurrentReservoir;
RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
}

struct ShadowRayData
{
    bool visible;
};

struct ScatterRayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    bool terminated; ///< Set to true when path is terminated.
    float3 thp;      ///< Current path throughput. This is updated at each path vertex.
    uint pathLength; ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;   ///< Next path segment origin.
    float3 normal;
    float3 direction; ///< Next path segment direction.
    float pdf;

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /**
     * Initializes ray payload with default parameters.
     */
    __init(SampleGenerator sg)
    {
        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.normal = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
        pdf = 0.f;
        this.sg = sg;
    }
};

uint getPixelIndex(uint2 pixel, uint2 frame)
{
    return pixel.x + pixel.y * frame.x;
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

    ShadowRayData rayData;
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

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

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
    bool V = traceShadowRay(origin, ls.dir, ls.distance);
    if (!V)
        return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

bool generateScatterRay(const ShadingData sd, const IMaterialInstance mi, bool isCurveHit, float3 rayOrigin, inout ScatterRayData rayData)
{
    BSDFSample bsdfSample;
    if (mi.sample(sd, rayData.sg, bsdfSample, true))
    {
        rayData.origin = rayOrigin;
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeRayOrigin(false);
        }
        rayData.normal = sd.faceN;
        rayData.direction = bsdfSample.wo;
        rayData.thp *= bsdfSample.weight;
        rayData.pdf = bsdfSample.pdf;
        return any(rayData.thp > 0.f);
    }
    return false;
}

void handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    let lod = ExplicitLodTextureSampler(0.f);

    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod);

    if (kUseEmissiveLights && rayData.pathLength > 0)
    {
        rayData.radiance += rayData.thp * mi.getProperties(sd).emission;
    }

    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.terminated = true;
        return;
    }

    float3 rayOrigin;
    rayOrigin = sd.computeRayOrigin();

    float3 Lr = evalDirectAnalytic(sd, mi, rayData.sg);
    rayData.radiance = rayData.thp * Lr;

    if (!generateScatterRay(sd, mi, false, rayOrigin, rayData))
    {
        rayData.terminated = true;
        return;
    }

    rayData.normal = sd.faceN;
    rayData.pathLength++;
}

float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        return -gViewW[launchIndex].xyz;
    }
    return camera.computeRayPinhole(launchIndex, launchDim).dir;
}

void traceScatterRay(inout ScatterRayData rayData)
{
    RayDesc ray;
    ray.Origin = rayData.origin;
    ray.Direction = rayData.direction;
    ray.TMin = 0.f;
    ray.TMax = FLT_MAX;

    uint rayFlags = 0;
    TraceRay(gScene.rtAccel, rayFlags, 0xff, 1, rayTypeCount, 1, ray, rayData);
}



Reservoir tracePath(const uint2 pixel, const uint2 frameDim)
{
    Reservoir reservoir;

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        float3 rayOrigin = sd.computeRayOrigin();

        // {
        //     // Emissive
        //     outColor += mi.getProperties(sd).emission;
        //     // Direct
        //     outColor += evalDirectAnalytic(sd, mi, sg);
        // }

        ScatterRayData rayData = ScatterRayData(sg);
        if (!generateScatterRay(sd, mi, false, rayOrigin, rayData))
        {
            rayData.terminated = true;
        }
        rayData.normal = sd.faceN;

        float3 visibleSurfacePosition = sd.posW;
        float3 visibleSurfaceNormal = sd.faceN;
        float3 secondarySurfacePosition = float3(0.f);
        float3 secondarySurfaceNormal = float3(0.f);
        for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
        {
            traceScatterRay(rayData);
            if (depth == 0 && !rayData.terminated)
            {
                secondarySurfacePosition = rayData.origin;
                secondarySurfaceNormal = rayData.normal;
            }
        }

        reservoir = Reservoir::makeReservoir(
            visibleSurfacePosition,
            visibleSurfaceNormal,
            secondarySurfacePosition,
            secondarySurfaceNormal, 
            rayData.radiance,
            rayData.pdf);
        
    }
    else
    {
        reservoir = Reservoir::makeEmpty();
    }

    return reservoir;
}

[shader("miss")]
void indirectMiss(inout ScatterRayData rayData)
{
    rayData.terminated = true;

    if (kUseEnvLight && rayData.pathLength > 0)
    {
        float3 Le = gScene.envMap.eval(WorldRayDirection());
        rayData.radiance += rayData.thp * Le;
    }
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    rayData.visible = true;
}

[shader("anyhit")]
void indirectAnyHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("closesthit")]
void indirectClosestHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    handleHit(HitInfo(triangleHit), rayData);
}

[shader("anyhit")]
void shadowAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);

    Reservoir reservoir = tracePath(pixel, frameDim);
    gCurrentReservoir[pixelIndex] = reservoir;
}
