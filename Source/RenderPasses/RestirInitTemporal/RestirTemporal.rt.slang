#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

Texture2D<float4> gMotionVector;
RWStructuredBuffer<Reservoir> gTemporalReservoirOld;
RWStructuredBuffer<Reservoir> gTemporalReservoirNew;
RWStructuredBuffer<Reservoir> gCurrentReservoir;
RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gInitialSamples;

    bool gEnableTemporal;
}

static const uint kMaxM = 30;
static const uint kMaxAge = 100;

int2 temporalResamplingOffset(int sampleIdx, int radius)
{
    sampleIdx &= 7;

    int mask2 = sampleIdx >> 1 & 0x01;       // 0, 0, 1, 1, 0, 0, 1, 1
    int mask4 = 1 - (sampleIdx >> 2 & 0x01); // 1, 1, 1, 1, 0, 0, 0, 0
    int tmp0 = -1 + 2 * (sampleIdx & 0x01);  // -1, 1,....
    int tmp1 = 1 - 2 * mask2;                // 1, 1,-1,-1, 1, 1,-1,-1
    int tmp2 = mask4 | mask2;                // 1, 1, 1, 1, 0, 0, 1, 1
    int tmp3 = mask4 | (1 - mask2);          // 1, 1, 1, 1, 1, 1, 0, 0

    return int2(tmp0, tmp0 * tmp1) * int2(tmp2, tmp3) * radius;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    Reservoir inputReservoir = gCurrentReservoir[pixelIndex];

    ShadingData inputShadingData;
    IMaterialInstance inputMaterialInstance;
    getShadingDataAndMaterial(inputShadingData, inputMaterialInstance, pixel, frameDim);

    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    int2 prevPos = pixel + int2(gMotionVector[pixel].xy * frameDim);

    uint2 pixelPrev;
    Reservoir temporalReservoir;
    bool foundTemporalReservoir = false;

    const int temporalSampleStartIdx = int(sampleNext1D(sampleGenerator) * 8);
    const int radius = 1;
    const int temporalSampleCount = 5;
    const int sampleCount = temporalSampleCount + 1;
    for (int i = 0; i < sampleCount; ++i)
    {
        const bool isFirstSample = i == 0;
        const bool isFallbackSample = i == temporalSampleCount;

        int2 offset = int2(0, 0);
        if (isFallbackSample)
        {
            prevPos = pixel;
        }
        else if (!isFirstSample)
        {
            offset = temporalResamplingOffset(temporalSampleStartIdx + i, radius);
        }

        int2 idx = prevPos + offset;

        if (any(idx < 0) || any(idx >= frameDim))
        {
            continue;
        }

        uint idxIndex = getPixelIndex(idx, frameDim);
        temporalReservoir = gTemporalReservoirOld[idxIndex];

        // Geometric similarity
        bool geometricSimilarity = validateGeometricSimilarity( inputReservoir.visiblePoint,
            inputReservoir.visibleNormal,
            temporalReservoir.visiblePoint,
            temporalReservoir.visibleNormal,
            gScene.camera.getViewProj()
        );

        if (!isFallbackSample && !geometricSimilarity)
        {
            continue;
        }

        if (!temporalReservoir.isValid())
        {
            continue;
        }

        foundTemporalReservoir = true;
        pixelPrev = idx;
        break;
    }

    Reservoir curReservoir = Reservoir::makeEmpty();

    float selectedTargetPdf = 0;
    if (inputReservoir.isValid())
    {
        selectedTargetPdf =
            getTargetPdfForSurface(inputShadingData, inputMaterialInstance, inputReservoir.samplePoint, inputReservoir.sampleRadiance);
        curReservoir.merge(inputReservoir, selectedTargetPdf, 0.5f);
    }

    if (foundTemporalReservoir)
    {
        float jacobian = calculateJacobian(inputReservoir.visiblePoint, temporalReservoir.visiblePoint, temporalReservoir);
        if (!validateSampleWithJacobian(jacobian))
        {
            foundTemporalReservoir = false;
        }

        temporalReservoir.weightSum *= jacobian;
        temporalReservoir.M = min(temporalReservoir.M, kMaxM);
        ++temporalReservoir.age;

        if (temporalReservoir.age > kMaxAge)
        {
            foundTemporalReservoir = false;
        }
    }

    bool selectedPreviousSample = false;
    if (!gInitialSamples && foundTemporalReservoir)
    {
        ShadingData shadingData;
        IMaterialInstance materialInstance;
        getShadingDataAndMaterial(shadingData, materialInstance, pixelPrev, frameDim);
        float targetPdf =
            getTargetPdfForSurface(shadingData, inputMaterialInstance, temporalReservoir.samplePoint, temporalReservoir.sampleRadiance);
        selectedPreviousSample = curReservoir.merge(temporalReservoir, targetPdf, sampleNext1D(sampleGenerator));
        if (selectedPreviousSample)
        {
            selectedTargetPdf = targetPdf;
        }
    }

    float normalizationNumerator = 1.f;
    float normalizationDenominator = selectedTargetPdf * curReservoir.M;
    curReservoir.finalize(normalizationNumerator, normalizationDenominator);

    gTemporalReservoirNew[pixelIndex] = curReservoir;
}
