#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

// static const uint kMaxBounces = MAX_BOUNCES;
// static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
// static const bool kUseEnvLight = USE_ENV_LIGHT;

static const uint kMaxBounces = 1;
static const bool kUseEmissiveLights = true;
static const bool kUseEnvLight = false;

struct SceneSample
{
    float3 visiblePoint;
    float3 visibleNormal;
    float3 samplePoint;
    float3 sampleNormal;
    float3 radiance;
    __init()
    {
        visiblePoint = float3(0);
        visibleNormal = float3(0);
        samplePoint = float3(0);
        sampleNormal = float3(0);
        radiance = float3(0);
    }
};

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

    [mutating]
    void update(SceneSample s, float weight, inout SampleGenerator sampleGenerator)
    {
        sampleRelativeWeight_w += weight;
        numStoredSamples_M += 1;
        if ((sampleNext1D(sampleGenerator) * sampleRelativeWeight_w) < weight)
        {
            sceneSample = s;
        }
    }

    [mutating]
    void merge(Reservoir r, float pHat, inout SampleGenerator sampleGenerator)
    {
        uint M0 = numStoredSamples_M;
        update(r.sceneSample, pHat * r.sceneSampleWeight_W * r.numStoredSamples_M, sampleGenerator);
        numStoredSamples_M = M0 + r.numStoredSamples_M;
    }
};

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

RWStructuredBuffer<Reservoir> gPreviousReservoir;
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
    float3 radiance;  ///< Accumulated outgoing radiance from path.
    bool terminated;  ///< Set to true when path is terminated.
    float3 thp;       ///< Current path throughput. This is updated at each path vertex.
    uint pathLength;  ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;    ///< Next path segment origin.
    float3 normal;
    float3 direction; ///< Next path segment direction.

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
        this.sg = sg;
    }
};

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

#define is_valid(name) (is_valid_##name != 0)
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

SceneSample tracePath(const uint2 pixel, const uint2 frameDim)
{
    SceneSample outSample;

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // Visible Point sample data
        outSample.visiblePoint = sd.posW;
        outSample.visibleNormal = sd.faceN;

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

        for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
        {
            traceScatterRay(rayData);
            // last trace will only apply emmision and will not generate new scatter ray
            if (depth == kMaxBounces - 1 && !rayData.terminated)
            {
                outSample.radiance = rayData.radiance;
            }
            //TODO: I think that the sample point and norml should be saved here when depth = 0 and is not terminated
        }

        outSample.samplePoint = rayData.origin;
        outSample.sampleNormal = rayData.normal;
    }
    else
    {
        outSample.radiance = float3(0.f);
    }

    return outSample;
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

    Reservoir reservoir;
    reservoir.sceneSample = tracePath(pixel, frameDim);
    gOutputColor[pixel] = float4(reservoir.sceneSample.radiance, 1.0f);
}
