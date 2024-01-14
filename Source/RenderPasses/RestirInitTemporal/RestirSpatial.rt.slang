#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

RWStructuredBuffer<Reservoir> gTemporalReservoir;
RWStructuredBuffer<Reservoir> gSpatialReservoir;
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

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);
    Reservoir inputReservoir = gTemporalReservoir[pixelIndex];

    ShadingData inputShadingData;
    IMaterialInstance inputMaterialInstance;
    getShadingDataAndMaterial(inputShadingData, inputMaterialInstance, pixel, frameDim);

    const uint numSamples = 15;
    const uint neighborSpan = 4;

    Reservoir curReservoir = Reservoir::makeEmpty();

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
        Reservoir neighborReservoir = gTemporalReservoir[idxIndex];

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

    gSpatialReservoir[pixelIndex] = curReservoir;
}
