#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "ReSTIRCommon.slangh"

Texture2D<float4> gMotionVector;

RWStructuredBuffer<DIReservoir> gTemporalReservoirOld_DI;
RWStructuredBuffer<DIReservoir> gTemporalReservoirNew_DI;
RWStructuredBuffer<DIReservoir> gInitialSamplesReservoir_DI;

RWStructuredBuffer<GIReservoir> gTemporalReservoirOld_GI;
RWStructuredBuffer<GIReservoir> gTemporalReservoirNew_GI;
RWStructuredBuffer<GIReservoir> gInitialSamplesReservoir_GI;

RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gInitialSamples;

    bool gEnableTemporal;
}

static const uint kMaxM = 30;
static const uint kMaxAge = 50;

DIReservoir diTemporalResampling(uint2 pixel, uint2 frameDim, DIReservoir inputReservoir, inout SampleGenerator sampleGenerator)
{
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    int2 prevPos = pixel + int2(gMotionVector[pixel].xy * frameDim);
    ShadingData shadingData;
    IMaterialInstance materialInstance;
    getShadingDataAndMaterial(shadingData, materialInstance, pixel, frameDim);

    if (any(prevPos < 0) || any(prevPos >= frameDim) || gInitialSamples)
    {
        return inputReservoir;
    }

    uint prevPosIndex = getPixelIndex(prevPos, frameDim);
    DIReservoir previousReservoir = gTemporalReservoirOld_DI[prevPosIndex];

    int lightIndex;
    float pHat = 0.f;
    DIReservoir temporalReservoir = DIReservoir::makeEmpty();

    lightIndex = inputReservoir.lightIndex;
    pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
    temporalReservoir.merge(inputReservoir, pHat, sampleNext1D(sampleGenerator));

    lightIndex = previousReservoir.lightIndex;
    pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
    temporalReservoir.M = min(temporalReservoir.M, 20 * inputReservoir.M);
    temporalReservoir.merge(previousReservoir, pHat, sampleNext1D(sampleGenerator));

    lightIndex = temporalReservoir.lightIndex;
    pHat = luminance(evalDirectAnalytic(shadingData, materialInstance, false, sampleGenerator, lightIndex));
    temporalReservoir.finalize(pHat);

    return temporalReservoir;
}

GIReservoir giTemporalResampling(uint2 pixel, uint2 frameDim, GIReservoir inputReservoir, inout SampleGenerator sampleGenerator)
{
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    ShadingData inputShadingData;
    IMaterialInstance inputMaterialInstance;
    getShadingDataAndMaterial(inputShadingData, inputMaterialInstance, pixel, frameDim);

    int2 prevPos = pixel + int2(gMotionVector[pixel].xy * frameDim);

    GIReservoir temporalReservoir;
    bool foundTemporalReservoir = false;

    if (all(prevPos >= 0) && all(prevPos < frameDim))
    {
        uint prevIdx = getPixelIndex(prevPos, frameDim);
        temporalReservoir = gTemporalReservoirOld_GI[prevIdx];

        // Geometric similarity
        bool geometricSimilarity = validateGeometricSimilarity(
            inputReservoir.visiblePoint,
            inputReservoir.visibleNormal,
            temporalReservoir.visiblePoint,
            temporalReservoir.visibleNormal,
            gScene.camera.data.viewProjMatNoJitter,
            false
        );

        foundTemporalReservoir = geometricSimilarity && temporalReservoir.isValid();
    }
    GIReservoir curReservoir = GIReservoir::makeEmpty();

    float selectedTargetPdf = 0;
    if (inputReservoir.isValid())
    {
        selectedTargetPdf =
            getTargetPdfForSurface(inputShadingData, inputMaterialInstance, inputReservoir.samplePoint, inputReservoir.sampleRadiance);
        curReservoir.merge(inputReservoir, selectedTargetPdf, 0.5f);
    }

    if (foundTemporalReservoir)
    {
        temporalReservoir.M = min(temporalReservoir.M, kMaxM);
    }

    bool selectedPreviousSample = false;
    if (!gInitialSamples && foundTemporalReservoir)
    {
        ShadingData shadingData;
        IMaterialInstance materialInstance;
        getShadingDataAndMaterial(shadingData, materialInstance, prevPos, frameDim);
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

    return curReservoir;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);
    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    DIReservoir diInputReservoir = gInitialSamplesReservoir_DI[pixelIndex];
    GIReservoir giInputReservoir = gInitialSamplesReservoir_GI[pixelIndex];

    DIReservoir diOutputReservoir = diInputReservoir;
    GIReservoir giOutputReservoir = giInputReservoir;
    if (gEnableTemporal)
    {
        diOutputReservoir = diTemporalResampling(pixel, frameDim, diInputReservoir, sampleGenerator);
        giOutputReservoir = giTemporalResampling(pixel, frameDim, giInputReservoir, sampleGenerator);
    }

    gTemporalReservoirNew_DI[pixelIndex] = diOutputReservoir;
    gTemporalReservoirNew_GI[pixelIndex] = giOutputReservoir;
}
