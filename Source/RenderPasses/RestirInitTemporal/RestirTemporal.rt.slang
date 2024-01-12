#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;

struct SceneSample
{
    float3 visiblePoint;
    float3 visibleNormal;
    float3 samplePoint;
    float3 sampleNormal;
    float3 radiance;
    float sourcePdf;
    __init()
    {
        visiblePoint = float3(0);
        visibleNormal = float3(0);
        samplePoint = float3(0);
        sampleNormal = float3(0);
        radiance = float3(0);
        sourcePdf = 0.f;
    }
};

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

uint getPixelIndex(uint2 pixel, uint2 frame)
{
    return pixel.x + pixel.y * frame.x;
}

float targetFunctionPDF(SceneSample inSample)
{
    // Simpler target function
    return luminance(inSample.radiance);
}

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

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);

    Reservoir currentReservoir = gCurrentReservoir[pixelIndex];

    // This is the 1st frame, no temporal data exists
    if (gInitialSamples || !gEnableTemporal)
    {
        gTemporalReservoirOld[pixelIndex] = currentReservoir;
        gTemporalReservoirNew[pixelIndex] = currentReservoir;
        return;
    }

    // int2 pixelPrev = uint2(((float2(pixel) / float2(frameDim)) + gMotionVector[pixel].xy) * frameDim);
    int2 pixelPrev = pixel + int2(gMotionVector[pixel].xy * frameDim);
    if (any(pixelPrev.xy < int2(0)) || any(pixelPrev.xy >= frameDim))
    {
        // can't do temporal reuse
        gTemporalReservoirNew[pixelIndex] = currentReservoir;
        return;
    }

    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);

    uint pixelIndexPrev = getPixelIndex(pixelPrev, frameDim);
    Reservoir previousReservoir = gTemporalReservoirOld[pixelIndexPrev];

    float w = targetFunctionPDF(currentReservoir.sceneSample) / currentReservoir.sceneSample.sourcePdf;
    previousReservoir.update(currentReservoir.sceneSample, w, sampleGenerator);
    previousReservoir.numStoredSamples_M = clamp(previousReservoir.numStoredSamples_M, 0, kMaxM);
    previousReservoir.sceneSampleWeight_W = previousReservoir.sampleRelativeWeight_w /
                                            (previousReservoir.numStoredSamples_M * targetFunctionPDF(previousReservoir.sceneSample));

    gTemporalReservoirNew[pixelIndex] = previousReservoir;
}
