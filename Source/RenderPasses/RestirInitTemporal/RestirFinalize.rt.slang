#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

RWStructuredBuffer<DIReservoir> gSpatialReservoir_DI;
RWStructuredBuffer<DIReservoir> gTemporalReservoirNew_DI;
RWStructuredBuffer<DIReservoir> gTemporalReservoirOld_DI;

RWStructuredBuffer<GIReservoir> gSpatialReservoir_GI;
RWStructuredBuffer<GIReservoir> gTemporalReservoirNew_GI;
RWStructuredBuffer<GIReservoir> gTemporalReservoirOld_GI;

Texture2D<float4> gDirectLightRadiance;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gDirectLight;
    bool gIndirectLight;
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

    if (gDirectLight)
    {
        DIReservoir diSpatialReservoir = gSpatialReservoir_DI[pixelIndex];
        int lightIndex = diSpatialReservoir.lightIndex;
        float3 diColor = evalDirectAnalytic(shadingData, materialInstance, true, sampleGenerator, lightIndex);
        float3 diRadiance = diColor * diSpatialReservoir.W;
        
        totalRadiance += diRadiance;
    }
    // totalRadiance += gDirectLightRadiance[pixel].xyz;

    if (gIndirectLight)
    {
        GIReservoir spatialReservoir = gSpatialReservoir_GI[pixelIndex];
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
    }
            
    gTemporalReservoirOld_DI[pixelIndex] = gTemporalReservoirNew_DI[pixelIndex];
    gTemporalReservoirOld_GI[pixelIndex] = gTemporalReservoirNew_GI[pixelIndex];

    gOutputColor[pixel] = float4(totalRadiance, 1.f);
}
