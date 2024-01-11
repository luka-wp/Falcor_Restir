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

float jacobianDeterminant(SceneSample qNeighbor, SceneSample rSource)
{
    float3 deltaQ = qNeighbor.visiblePoint - qNeighbor.samplePoint;
    float3 deltaR = rSource.visiblePoint - qNeighbor.samplePoint;
    float dq2 = dot(deltaQ, deltaQ);
    float dr2 = dot(deltaR, deltaR);
    float cosQ = dot(qNeighbor.sampleNormal, normalize(deltaQ));
    float cosR = dot(qNeighbor.sampleNormal, normalize(deltaR));
    float denum = cosQ * dr2;

    if (denum <= 0.f)
        return 0.f;

    return (cosR * dq2) / denum;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

RWStructuredBuffer<Reservoir> gTemporalReservoir;
RWStructuredBuffer<Reservoir> gSpatialReservoir;
RWTexture2D<float4> gOutputColor;

cbuffer CB
{
    uint gFrameCount;
    bool gInitialSamples;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint pixelIndex = getPixelIndex(pixel, frameDim);

    SampleGenerator sampleGenerator = SampleGenerator(pixel, gFrameCount);
    const uint numNeighbors = 5;
    const uint neighborSpan = 4;

    Reservoir temporalReservoir = gTemporalReservoir[pixelIndex];
    uint Z = temporalReservoir.numStoredSamples_M;
    for (int counter = 0; counter < numNeighbors; ++counter)
    {
        int2 offset = int2(lerp(float2(-neighborSpan), float2(neighborSpan + 1), sampleNext2D(sampleGenerator)));
        int2 pixelNeighbor = pixel + offset;
        if (any(pixelNeighbor < 0) || any(pixelNeighbor >= frameDim) || all(offset == 0))
        {
            continue;
        }

        uint pixelNeighborIndex = getPixelIndex(pixelNeighbor, frameDim);
        Reservoir temporalReservoirNeighbor = gTemporalReservoir[pixelNeighborIndex];
        // TODO: Geometric similarity

        float jacobian = jacobianDeterminant(temporalReservoirNeighbor.sceneSample, temporalReservoir.sceneSample);
        float pHat = targetFunctionPDF(temporalReservoirNeighbor.sceneSample);
        float pHatP = 0.f;
        // TODO: Check if neighbor sample point is visible to destination visible point
        if (jacobian != 0.f)
        {
            pHatP = pHat / jacobian;
        }

        temporalReservoir.merge(temporalReservoirNeighbor, pHatP, sampleGenerator);
        Z += temporalReservoirNeighbor.numStoredSamples_M;
    }

    temporalReservoir.sceneSampleWeight_W =
        temporalReservoir.sampleRelativeWeight_w / (Z * targetFunctionPDF(temporalReservoir.sceneSample));

    gSpatialReservoir[pixelIndex] = temporalReservoir;
}
