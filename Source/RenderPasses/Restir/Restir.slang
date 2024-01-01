#include "Scene/SceneDefines.slangh"
import Scene.Raster;

cbuffer PerFrameCB
{
    float4 gColor;
};

VSOut vsMain(VSIn vIn)
{
    return defaultVS(vIn);
}

float4 psMain(VSOut vsOut) : SV_TARGET
{
    return gColor;
}
