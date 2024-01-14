#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

RWStructuredBuffer<Reservoir> gSpatialReservoir;
RWStructuredBuffer<Reservoir> gTemporalReservoirNew;
RWStructuredBuffer<Reservoir> gTemporalReservoirOld;

Texture2D<float4> gDirectLightRadiance;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
}

struct ShadowRayData
{
    bool visible;
};

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

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    rayData.visible = true;
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

    ShadingData shadingData;
    IMaterialInstance materialInstance;
    getShadingDataAndMaterial(shadingData, materialInstance, pixel, frameDim);
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    float3 totalRadiance = float3(0.f);

    totalRadiance += gDirectLightRadiance[pixel].xyz;

    Reservoir spatialReservoir = gSpatialReservoir[pixelIndex];
    float3 woDelta = spatialReservoir.samplePoint - shadingData.posW;
    float woDist = length(woDelta);
    float3 wo = woDelta / woDist;
    bool indirectVisible = traceShadowRay(shadingData.posW, wo, woDist);
    if (indirectVisible)
    {
        float3 surfaceColor = materialInstance.eval(shadingData, wo, sampleGenerator);
        float3 indirectRadiance = surfaceColor * spatialReservoir.sampleRadiance * spatialReservoir.weightSum;

        totalRadiance += indirectRadiance;
    }


    Reservoir temporalOld = gTemporalReservoirOld[pixelIndex];
    gTemporalReservoirOld[pixelIndex] = gTemporalReservoirNew[pixelIndex];

    gOutputColor[pixel] = float4(totalRadiance, 1.f);
}
