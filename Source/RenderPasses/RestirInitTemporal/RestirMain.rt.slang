#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;

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

cbuffer CB
{
    uint gFrameCount;
    bool gInitLights;
    bool gTemporalReuse;
    bool gIndirectLight;
    float4x4 gPrevViewMatrix;
}

Texture2D<float4> gPositionW;
Texture2D<float4> gNormalW;
Texture2D<float4> gTangentW;
Texture2D<float4> gDiffuseColor;
Texture2D<PackedHitInfo> gVBuffer;

RWStructuredBuffer<Reservoir> gPreviousReservoir;
RWStructuredBuffer<Reservoir> gCurrentReservoir;
RWTexture2D<float4> gOutputColor;

struct ShadowRayPayload
{
    bool visible;
};

struct IndirectRayPayload
{
    float3 rayDirection;

    float3 positionW;
    float3 normalW;
    float3 radiance;

    SampleGenerator sampleGenerator;

    __init(SampleGenerator sg)
    {
        rayDirection = float3(0);

        positionW = float3(0);
        normalW = float3(0);
        radiance = float3(0);

        sampleGenerator = sg;
    }
};

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
    rayData.radiance = float3(0.f);
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

AnalyticLightSample getLightSample(float3 posW, inout int lightIndex, inout SampleGenerator sampleGenerator)
{
    AnalyticLightSample lightSample;
    uint lightCount = gScene.lightCount;
    if (lightCount == 0)
    {
        return lightSample;
    }

    uint index = (lightIndex >= 0) ? lightIndex : min(uint(lightCount * sampleNext1D(sampleGenerator)), lightCount - 1);
    LightData lightData = gScene.getLight(index);
    if (lightData.type != uint(LightType::Point))
    {
        return lightSample;
    }

    if (!sampleLight(posW, lightData, sampleGenerator, lightSample))
    {
        return lightSample;
    }

    lightIndex = index;
    return lightSample;
}

// float3 evalRadiance(float3 diffuseColor, float3 surfaceNormalW, AnalyticLightSample lightSample)
// {
//     float NdotL = dot(surfaceNormalW, lightSample.dir);
//     if (NdotL <= 0.f)
//     {
//         return float3(0.f);
//     }

//     return diffuseColor * lightSample.Li * NdotL * M_1_PI;
// }

float3 evalMaterialRadiance(float3 inLightRadiance, ShadingData shadingData, IMaterialInstance materialInstance, AnalyticLightSample lightSample, inout SampleGenerator sampleGenerator)
{
    return materialInstance.eval(shadingData, lightSample.dir, sampleGenerator) * inLightRadiance;
}

// float evalPHat(float3 diffuseColor, float3 surfaceNormalW, AnalyticLightSample lightSample)
// {
//     return luminance(evalRadiance(diffuseColor, surfaceNormalW, lightSample));
// }

float evalPHat(float3 inLightRadiance, ShadingData shadingData, IMaterialInstance materialInstance, AnalyticLightSample lightSample, inout SampleGenerator sampleGenerator)
{
    return luminance(evalMaterialRadiance(inLightRadiance, shadingData, materialInstance, lightSample, sampleGenerator));
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    VertexData v = {};
    uint materialID = {};

    const TriangleHit triangleHit = hit.getTriangleHit();
    v = gScene.getVertexData(triangleHit);
    materialID = gScene.getMaterialID(triangleHit.instanceID);

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

[shader("closesthit")]
void indirectClosestHit(inout IndirectRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData vertexData = gScene.getVertexData(triangleHit);

    rayData.positionW = vertexData.posW;
    rayData.normalW = vertexData.normalW;

    int lightIndex = -1;
    AnalyticLightSample lightSample = getLightSample(vertexData.posW, lightIndex, rayData.sampleGenerator);
    float3 shadowRayOrigin = vertexData.posW + vertexData.normalW * 0.001f;
    
    HitInfo hitInfo = HitInfo(triangleHit);
    let lod = ExplicitLodTextureSampler(0.f);
    
    ShadingData shadingData = loadShadingData(hitInfo, rayData.rayDirection, lod);
    IMaterialInstance materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);
    float3 materialRadiance = evalMaterialRadiance(lightSample.Li, shadingData, materialInstance, lightSample, rayData.sampleGenerator);
    bool inShadow = traceShadowRay(shadowRayOrigin, lightSample.dir, lightSample.distance);
    rayData.radiance = !inShadow ? float3(0.f) : materialRadiance;
}

uint getPixelIndex(uint2 pixel, uint2 frame)
{
    return pixel.x + pixel.y * frame.x;
}

float3 getRandomDirection(float3 normal, float3 tangent, out float pdf, SampleGenerator sampleGenerator)
{
    float3 bitangent = normalize(cross(normal, tangent));
    float3 wo = sample_cosine_hemisphere_concentric(sampleNext2D(sampleGenerator), pdf);
    return normalize(wo.x * tangent + wo.y * bitangent * wo.z * normal);
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixelXY = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixelXY, frameDim);
    SampleGenerator sampleGenerator = SampleGenerator(pixelXY, gFrameCount);

    float4 posW = gPositionW[pixelXY];
    float3 normalW = gNormalW[pixelXY].xyz;
    float3 tangentW = gTangentW[pixelXY].xyz;
    float3 diffuse = gDiffuseColor[pixelXY].xyz;

    // float4 prevClip = mul(float4(posW.xyz, 1.f), gPrevViewMatrix);
    // float3 prevScreen = prevClip.xyz / prevClip.w;
    // float2 prevUV = prevScreen.xy * float2(0.5f, -0.5f) + 0.5f;
    // uint2 prevPixelXY = clamp(uint2(prevUV * frameDim), uint2(0), frameDim.xy - 1);
    // uint prevPixelIndex = getPixelIndex(prevPixelXY, frameDim);

    // bool isPrevValid = all(prevPixelXY >= 0) && all(prevPixelXY < frameDim);
    // if (isPrevValid)
    // {
    //     float4 prevPosW = gPositionW[prevPixelXY];
    //     float3 prevNormalW = gNormalW[prevPixelXY].xyz;

    //     isPrevValid &= length(posW.xyz - prevPosW.xyz) < 0.1f && dot(normalW, prevNormalW) > 0.8f;
    // }

    // Initial sample
    Reservoir reservoir;

    // Visible point
    reservoir.sceneSample.visiblePoint = posW.xyz;
    reservoir.sceneSample.visibleNormal = normalW;

    // Sampled point
    HitInfo hit = HitInfo(gVBuffer[pixelXY]);
    let lod = ExplicitLodTextureSampler(0.f);
    float3 cameraRayDir = gScene.camera.computeRayPinhole(pixelXY, frameDim).dir;
    ShadingData shadingData = loadShadingData(hit, cameraRayDir, lod);
    IMaterialInstance materialInstance = gScene.materials.getMaterialInstance(shadingData, lod);

    RayDesc rayDesc;
    float samplePointDirPdf = 0.f;
    rayDesc.Origin = shadingData.computeRayOrigin();
    // rayDesc.Origin = posW.xyz + normalW * 0.001f;
    BSDFSample bsdfSample;
    materialInstance.sample(shadingData, sampleGenerator, bsdfSample, false);
    rayDesc.Direction = bsdfSample.wo;
    // rayDesc.Direction = getRandomDirection(normalW, tangentW, samplePointDirPdf, sampleGenerator);
    rayDesc.TMin = 0.f;
    rayDesc.TMax = FLT_MAX;
    IndirectRayPayload rayPayload = IndirectRayPayload(sampleGenerator);
    rayPayload.rayDirection = rayDesc.Direction;
    TraceRay(gScene.rtAccel, 0, 0xff, 1, rayTypeCount, 1, rayDesc, rayPayload);

    reservoir.sceneSample.samplePoint = rayPayload.positionW;
    reservoir.sceneSample.sampleNormal = rayPayload.normalW;
    reservoir.sceneSample.radiance = rayPayload.radiance;

    //~~~~ Silly test
    int lightIndex = -1;
    AnalyticLightSample lightSample = getLightSample(posW.xyz, lightIndex, sampleGenerator);
    // float3 directRadiance = evalMaterialRadiance(lightSample.Li, shadingData, materialInstance, lightSample, sampleGenerator);
    bool inShadow = traceShadowRay(shadingData.computeRayOrigin(), lightSample.dir, lightSample.distance);
    float3 rd = !inShadow ? reservoir.sceneSample.radiance : reservoir.sceneSample.radiance + lightSample.Li;
    float3 directRadiance = evalMaterialRadiance(rd, shadingData, materialInstance, lightSample, sampleGenerator);
    //~~~~
    gOutputColor[pixelXY] = float4(reservoir.sceneSample.radiance, 1.0f);
}
