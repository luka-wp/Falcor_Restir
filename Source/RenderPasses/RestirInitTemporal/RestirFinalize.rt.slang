#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

RWStructuredBuffer<Reservoir> gSpatialReservoir;
RWStructuredBuffer<Reservoir> gTemporalReservoirNew;
RWStructuredBuffer<Reservoir> gTemporalReservoirOld;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
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

    Reservoir spatialReservoir = gSpatialReservoir[pixelIndex];
    float3 wo = normalize(spatialReservoir.samplePoint - shadingData.posW);
    float3 surfaceColor = materialInstance.eval(shadingData, wo, sampleGenerator);

    float3 indirectColor = surfaceColor * spatialReservoir.sampleRadiance * spatialReservoir.weightSum;

    Reservoir temporalOld = gTemporalReservoirOld[pixelIndex];
    gTemporalReservoirOld[pixelIndex] = gTemporalReservoirNew[pixelIndex];

    gOutputColor[pixel] = float4(indirectColor, 1.f);
}
