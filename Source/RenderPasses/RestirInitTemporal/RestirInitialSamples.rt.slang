#include "Scene/SceneDefines.slangh"

#include "ReSTIRCommon.slangh"

static const uint kMaxBounces = 2;
static const bool kUseEmissiveLights = false;
static const bool kUseEnvLight = false;

static const uint kSampleCount = 32;

RWStructuredBuffer<DIReservoir> gInitialSamplesReservoir_DI;
RWStructuredBuffer<GIReservoir> gInitialSamplesReservoir_GI;
RWTexture2D<float4> gDirectLightRadiance;

cbuffer CB
{
    uint gFrameCount;
}

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

    int lightIndex = -1;
    float3 Lr = evalDirectAnalytic(sd, mi, true, rayData.sg, lightIndex);
    rayData.radiance += rayData.thp * Lr;

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

float3 tracePath(const uint2 pixel, const uint2 frameDim, out DIReservoir outDIReservoir, out GIReservoir outGIReservoir)
{
    DIReservoir diReservoir = DIReservoir::makeEmpty();
    GIReservoir giReservoir = GIReservoir::makeEmpty();
    float3 outRadiance = float3(0.f);

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

        // Initial DI sample
        {
            float3 diRadiance = float3(0.f);
            // Emissive
            if (kUseEmissiveLights)
            {
                diRadiance += mi.getProperties(sd).emission;
            }
            // Direct
            float pHat = 0.f;
            for (int i = 0; i < min(gScene.lightCount, kSampleCount); ++i)
            {
                int lightIndex = -1;
                float3 lightRadiance = evalDirectAnalytic(sd, mi, false, sg, lightIndex);
                pHat = luminance(lightRadiance);
                diReservoir.update(lightIndex, pHat, sampleNext1D(sg));
            }

            float3 lightRadiance = evalDirectAnalytic(sd, mi, true, sg, diReservoir.lightIndex);
            pHat = luminance(lightRadiance);
            diReservoir.finalize(pHat);

            diRadiance += lightRadiance * diReservoir.W;
            outRadiance = diRadiance;
        }

        ScatterRayData rayData = ScatterRayData(sg);
        if (!generateScatterRay(sd, mi, false, rayOrigin, rayData))
        {
            rayData.terminated = true;
        }
        rayData.normal = sd.faceN;

        float3 visibleSurfacePosition = sd.posW;
        float3 visibleSurfaceNormal = sd.faceN;
        float3 secondarySurfacePosition = float3(0);
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

        {
            giReservoir = GIReservoir::makeReservoir(
                visibleSurfacePosition,
                visibleSurfaceNormal,
                secondarySurfacePosition,
                secondarySurfaceNormal,
                rayData.radiance,
                1.f
            );
        }
    }

    outDIReservoir = diReservoir;
    outGIReservoir = giReservoir;

    return outRadiance;
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

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);

    DIReservoir diReservoir;
    GIReservoir giReservoir;
    float3 diRadiance = tracePath(pixel, frameDim, diReservoir, giReservoir);

    gInitialSamplesReservoir_DI[pixelIndex] = diReservoir;
    gInitialSamplesReservoir_GI[pixelIndex] = giReservoir;

    gDirectLightRadiance[pixel] = float4(diRadiance, 1.f);
}
