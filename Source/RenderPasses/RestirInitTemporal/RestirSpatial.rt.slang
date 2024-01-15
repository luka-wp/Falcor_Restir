#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

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
        // int2(0, 0),
        int2(1, 0),
        int2(-1, 1),
        int2(0, 1),
        int2(1, 1)
    };
    return int2(float2(offsets[sampleIdx]) * radius);
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
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);
    GIReservoir giInputReservoir = gTemporalReservoir_GI[pixelIndex];

    GIReservoir giOutputReservoir = giInputReservoir;
    if (gEnableSpatial)
    {
        giOutputReservoir = giSpatialResampling(pixel, frameDim, giInputReservoir, sampleGenerator);
    }

    gSpatialReservoir_GI[pixelIndex] = giOutputReservoir;
}
