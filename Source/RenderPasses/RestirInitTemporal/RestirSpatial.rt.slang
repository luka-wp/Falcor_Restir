#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

RWStructuredBuffer<DIReservoir> gTemporalReservoir_DI;
RWStructuredBuffer<DIReservoir> gSpatialReservoir_DI;

RWStructuredBuffer<GIReservoir> gTemporalReservoir_GI;
RWStructuredBuffer<GIReservoir> gSpatialReservoir_GI;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gEnableSpatial;
}

int2 calculateSpatialResamplingOffset(int sampleIdx, float radius)
{
    sampleIdx &= 7;
    int2 offsets[8] = {
        int2(-1, -1),
        int2(0, -1),
        int2(1, -1),
        int2(-1, 0),
        int2(1, 0),
        int2(-1, 1),
        int2(0, 1),
        int2(1, 1)
    };
    return int2(float2(offsets[sampleIdx]) * radius);
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
    const uint kNeighborCount = 4;
    for (int i = 0; i < kNeighborCount; ++i)
    {
        int2 offset = calculateSpatialResamplingOffset(baseIndex + i + 3, 1);
        uint2 nbPixel = clamp(pixel + offset, uint2(0), frameDim - 1);
        uint nbPixelIndex = getPixelIndex(nbPixel, frameDim);

        DIReservoir nbReservoir = gTemporalReservoir_DI[nbPixelIndex];

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
    const uint neighborSpan = 4;

    GIReservoir curReservoir = GIReservoir::makeEmpty();

    float selectedTargetPdf = 0.f;
    if (inputReservoir.isValid())
    {
        selectedTargetPdf =
            getTargetPdfForSurface(inputShadingData, inputMaterialInstance, inputReservoir.samplePoint, inputReservoir.sampleRadiance);

        curReservoir.merge(inputReservoir, selectedTargetPdf, 0.5f);
    }

    uint cachedResult = 0;
    int selected = -1;

    const int neighborSampleStartIdx = int(sampleNext1D(sampleGenerator) * 8);
    const float radius = 1.f;
    for (int i = 0; i < numSamples; ++i)
    {
        int2 idx = pixel + calculateSpatialResamplingOffset(neighborSampleStartIdx + i, radius);
        idx = clamp(idx, int2(0), frameDim - 1);

        uint idxIndex = getPixelIndex(idx, frameDim);
        GIReservoir neighborReservoir = gTemporalReservoir_GI[idxIndex];

        bool geometricSimilarity = validateGeometricSimilarity(
            inputReservoir.visiblePoint,
            inputReservoir.visibleNormal,
            neighborReservoir.visiblePoint,
            neighborReservoir.visibleNormal,
            gScene.camera.getViewProj()
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

        cachedResult |= (1u << uint(i));

        bool isUpdated = curReservoir.merge(neighborReservoir, targetPdf * jacobian, sampleNext1D(sampleGenerator));
        if (isUpdated)
        {
            selected = i;
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

    DIReservoir diInputReservoir = gTemporalReservoir_DI[pixelIndex];
    GIReservoir giInputReservoir = gTemporalReservoir_GI[pixelIndex];
    
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    DIReservoir diOutputReservoir = diInputReservoir;
    GIReservoir giOutputReservoir = giInputReservoir;
    if (gEnableSpatial)
    {
        diOutputReservoir = diSpatialResampling(pixel, frameDim, diInputReservoir, sampleGenerator);
        giOutputReservoir = giSpatialResampling(pixel, frameDim, giInputReservoir, sampleGenerator);
    }

    gSpatialReservoir_DI[pixelIndex] = diOutputReservoir;
    gSpatialReservoir_GI[pixelIndex] = giOutputReservoir;
}
