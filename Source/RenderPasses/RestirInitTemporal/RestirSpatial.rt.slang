#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

static const int kNeighborSamples = 5;
static const int kNeighborRadius = 30;

RWStructuredBuffer<DIReservoir> gSpatialReservoir_DI;
RWStructuredBuffer<DIReservoir> gTemporalReservoir_DI;

RWStructuredBuffer<GIReservoir> gSpatialReservoir_GI;
RWStructuredBuffer<GIReservoir> gTemporalReservoir_GI;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gEnableSpatial;
    bool gDirectLight;
    bool gIndirectLight;
    bool gClearBuffers;
}

int2 calcNeighborPixel(uint2 pixel, uint2 frameDim, int radius, inout SampleGenerator sampleGenerator)
{
    float2 alpha = float2(-1.f) + float2(2.f) * sampleNext2D(sampleGenerator);
    int2 offset = int2(alpha * radius);
    int2 neighbor = pixel + offset;
    return clamp(neighbor, int2(0), frameDim - 1);
}

DIReservoir diSpatialResampling(uint2 pixel, uint2 frameDim, DIReservoir inputReservoir, SampleGenerator sampleGenerator)
{
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    ShadingData shadingData;
    IMaterialInstance materialInstance;
    getShadingDataAndMaterial(shadingData, materialInstance, pixel, frameDim);

    float pHat = 0.f;
    int lightIndex = -1;
    DIReservoir spatialReservoir = DIReservoir::makeEmpty();

    lightIndex = inputReservoir.lightIndex;
    pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
    spatialReservoir.merge(inputReservoir, pHat, sampleNext1D(sampleGenerator));

    const int baseIndex = sampleNext1D(sampleGenerator) * 8;
    for (int i = 0; i < kNeighborSamples; ++i)
    {
        uint2 nbPixel = calcNeighborPixel(pixel, frameDim, kNeighborRadius, sampleGenerator);
        uint nbPixelIndex = getPixelIndex(nbPixel, frameDim);

        DIReservoir nbReservoir = gSpatialReservoir_DI[nbPixelIndex];

        lightIndex = nbReservoir.lightIndex;
        pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
        spatialReservoir.merge(nbReservoir, pHat, sampleNext1D(sampleGenerator));
    }

    lightIndex = spatialReservoir.lightIndex;
    pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
    spatialReservoir.finalize(pHat);

    return spatialReservoir;
}

GIReservoir giSpatialResampling(uint2 pixel, uint2 frameDim, GIReservoir inputReservoir, SampleGenerator sampleGenerator)
{
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    ShadingData inputShadingData;
    IMaterialInstance inputMaterialInstance;
    getShadingDataAndMaterial(inputShadingData, inputMaterialInstance, pixel, frameDim);

    const uint numSamples = 15;

    GIReservoir curReservoir = GIReservoir::makeEmpty();

    float selectedTargetPdf = 0.f;
    if (inputReservoir.isValid())
    {
        selectedTargetPdf =
            getTargetPdfForSurface(inputShadingData, inputMaterialInstance, inputReservoir.samplePoint, inputReservoir.sampleRadiance);

        curReservoir.merge(inputReservoir, selectedTargetPdf, 0.5f);
    }

    const int neighborSampleStartIdx = int(sampleNext1D(sampleGenerator) * 8);
    const float radius = 1.f;
    for (int i = 0; i < kNeighborSamples; ++i)
    {
        int2 idx = calcNeighborPixel(pixel, frameDim, kNeighborRadius, sampleGenerator);

        uint idxIndex = getPixelIndex(idx, frameDim);
        GIReservoir neighborReservoir = gSpatialReservoir_GI[idxIndex];

        bool geometricSimilarity = validateGeometricSimilarity(
            inputReservoir.visiblePoint,
            inputReservoir.visibleNormal,
            neighborReservoir.visiblePoint,
            neighborReservoir.visibleNormal,
            gScene.camera.data.viewProjMatNoJitter,
            true
        );

        if (!geometricSimilarity)
        {
            continue;
        }

        float jacobian = calculateJacobian(inputReservoir.visiblePoint, neighborReservoir.visiblePoint, neighborReservoir);

        ShadingData shadingData;
        IMaterialInstance materialInstance;
        getShadingDataAndMaterial(shadingData, materialInstance, idx, frameDim);
        float targetPdf =
            getTargetPdfForSurface(shadingData, inputMaterialInstance, inputReservoir.samplePoint, neighborReservoir.sampleRadiance);

        if (!validateSampleWithJacobian(jacobian))
        {
            continue;
        }

        bool isUpdated = curReservoir.merge(neighborReservoir, targetPdf * jacobian, sampleNext1D(sampleGenerator));
        if (isUpdated)
        {
            selectedTargetPdf = targetPdf;
        }
    }

    float numerator = 1.f;
    float denominator = curReservoir.M * selectedTargetPdf;
    curReservoir.finalize(numerator, denominator);

    return curReservoir;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);
    ShadingData shadingData;
    IMaterialInstance materialInstance;
    getShadingDataAndMaterial(shadingData, materialInstance, pixel, frameDim);

    DIReservoir diInputReservoir = gSpatialReservoir_DI[pixelIndex];
    GIReservoir giInputReservoir = gSpatialReservoir_GI[pixelIndex];
    
    // Spatial resampling
    DIReservoir diOutputReservoir = diInputReservoir;
    GIReservoir giOutputReservoir = giInputReservoir;
    if (gEnableSpatial)
    {
        diOutputReservoir = diSpatialResampling(pixel, frameDim, diInputReservoir, sampleGenerator);
        giOutputReservoir = giSpatialResampling(pixel, frameDim, giInputReservoir, sampleGenerator);
    }

    // Save prev reservoirs to temporal buffer
    if (!gClearBuffers)
    {
        gTemporalReservoir_DI[pixelIndex] = diInputReservoir;
        gTemporalReservoir_GI[pixelIndex] = giInputReservoir;
    }
    else
    {
        gTemporalReservoir_DI[pixelIndex] = DIReservoir::makeEmpty();
        gTemporalReservoir_GI[pixelIndex] = GIReservoir::makeEmpty();
    }

    // Final shading
    float3 totalRadiance = float3(0.f);
    if (gDirectLight)
    {
        int lightIndex = diOutputReservoir.lightIndex;
        float3 diColor = evalDirectAnalytic(shadingData, materialInstance, true, sampleGenerator, lightIndex);
        float3 diRadiance = diColor * diOutputReservoir.W;

        totalRadiance += diRadiance;
    }

    if (gIndirectLight)
    {
        float3 indirectRadiance = giOutputReservoir.sampleRadiance * giOutputReservoir.weightSum;
        totalRadiance += indirectRadiance;
    }

    gOutputColor[pixel] = float4(totalRadiance, 1.f);

}
