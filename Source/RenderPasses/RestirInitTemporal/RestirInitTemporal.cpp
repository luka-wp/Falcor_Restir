/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "RestirInitTemporal.h"

#include "RenderGraph/RenderPassHelpers.h"

namespace
{
/* >> ReSTIR 3 >> */
const char* kInitSamplesShaderFile = "RenderPasses/RestirInitTemporal/RestirInitialSamples.rt.slang";
const char* kTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirTemporal.rt.slang";
const char* kSpatialShaderFile = "RenderPasses/RestirInitTemporal/RestirSpatial.rt.slang";
const char* kFinalizeShaderFile = "RenderPasses/RestirInitTemporal/RestirFinalize.rt.slang";

const ChannelList kInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility buffer in packed format", true},
    {"viewW", "gViewW", "World-space view direction (xyz float format)", true},
    {"motionVector", "gMotionVector", "Screen space motion vector", true}
};

const char* kOutputColor = "outputColor";
const ChannelList kOutputChannels = {
    {kOutputColor, "gOutputColor", "Output color", false, ResourceFormat::RGBA32Float}};

/* << ReSTIR 3 << */

const char* kInitTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirInitialSamples.rt.slang";
//const char* kInitTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirMain.rt.slang";
//const char* kInitTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirInitTemporal.rt.slang";
const char* kSpatialReuseShaderFile = "RenderPasses/RestirInitTemporal/RestirSpatial.rt.slang";
//const char* kSpatialReuseShaderFile = "RenderPasses/RestirInitTemporal/RestirSpatialReuse.rt.slang";
const char* kUpdateShadeShaderFile = "RenderPasses/RestirInitTemporal/RestirUpdateReservoirShade.rt.slang";

const uint32_t kMaxPayloadSizeBytes = 96u;
const uint32_t kMaxRecursionDepth = 2u;

const char* kEntryRayGen = "rayGen";

const char* kEntryShadowMiss = "shadowMiss";
const char* kEntryShadowAnyHit = "shadowAnyHit";
const char* kEntryShadowClosestHit = "shadowClosestHit";

const char* kEntryIndirectMiss = "indirectMiss";
const char* kEntryIndirectAnyHit = "indirectAnyHit";
const char* kEntryIndirectClosestHit = "indirectClosestHit";

const char* kInputPositionWorld = "posW";            //RGBA32Float
const char* kInputNormalWorld = "normW";             //RGBA32Float
const char* kInputTangentWorld = "tangentW";         //RGBA32Float
const char* kInputDiffuseOpacity = "diffuseOpacity"; // RGBA32Float

//const ChannelList kInitInputChannels = {
//    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
//    {"viewW", "gViewW", "World-space view direction (xyz float format)", true},
//    //{"motionVector", "gMotionVector", "Screen space motion vector"}
//};

//const ChannelList kTemporalInputChannels = {
//    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
//    {"viewW", "gViewW", "World-space view direction (xyz float format)", true},
//    //{"motionVector", "gMotionVector", "Screen space motion vector"}
//};

//const ChannelList kTemporalInputChannels = {
//    {kInputPositionWorld, "gPositionW", ""},
//    {kInputNormalWorld, "gNormalW", ""},
//    {kInputTangentWorld, "gTangentW", ""},
//    {kInputDiffuseOpacity, "gDiffuseColor", ""},
//    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
//};

const ChannelList kSpatialInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility bufferin packed format"},
    {"viewW", "gViewW", "World-space view direction", true},
};

const ChannelList kUpdateShadeInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility bufferin packed format"},
    {"viewW", "gViewW", "World-space view direction", true},
};

const char* kReservoirCurrent = "reservoirCurrent";
const char* kReservoirPrevious = "reservoirPrevious";
const char* kReservoirSpatial = "reservoirSpatial";


const ChannelList kTemporalOutputChannels = {
    //{kReservoirCurrent, "gReservoirCurrent", "Current reservoir state", false, ResourceFormat::RGBA32Float},
    //{kReservoirPrevious, "gReservoirPrevious", "Previous reservoir state", false, ResourceFormat::RGBA32Float},
    {kOutputColor, "gOutputColor", "Output color", false, ResourceFormat::RGBA32Float}
};

const ChannelList kSpatialOutputChannels = {
    {kReservoirSpatial, "gReservoirSpatial", "Spatial reservoir state", false, ResourceFormat::RGBA32Float}};

const ChannelList kUpdateShadeOutputChannels = {
    {kReservoirSpatial, "gReservoirSpatial", "Spatial reservoir state", false, ResourceFormat::RGBA32Float},
    {kReservoirPrevious, "gReservoirPrevious", "Previous reservoir state", false, ResourceFormat::RGBA32Float},
    {kOutputColor, "gOutputColor", "Output color", false, ResourceFormat::RGBA32Float}
};
}; // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, RestirInitTemporal>();
}

RestirInitTemporal::RestirInitTemporal(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties RestirInitTemporal::getProperties() const
{
    return {};
}

RenderPassReflection RestirInitTemporal::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kTemporalOutputChannels);
    //addRenderPassOutputs(reflector, kUpdateShadeOutputChannels);
    return reflector;
}

void RestirInitTemporal::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        for (auto it : kTemporalOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
            {
                pRenderContext->clearTexture(pDst);
            }
        }
        return;
    }

    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    mTracerInit.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    //mTracerTemporal.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerSpatial.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerFinalize.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));

    //if (!mTracerTemporal.pVars || !mTracerSpatial.pVars)
    if (!mTracerTemporal.pVars)
    {
        prepareVars();
    }

    const uint2 dims = renderData.getDefaultTextureDims();
    allocateReservoir(dims.x, dims.y);

    executeInitSamplesAndTemporalProgram(pRenderContext, renderData);
    executeSpatialResamplingAndFinalizeProgram(pRenderContext, renderData);
    mClearBuffers = false;

    //executeCopyTemporalProgram(pRenderContext, renderData);

    //executeInitSamples(pRenderContext, renderData);
    //executeTemporal(pRenderContext, renderData);
    //executeSpatial(pRenderContext, renderData);
    //executeFinalize(pRenderContext, renderData);

    //executeInitTemporal(pRenderContext, renderData);

    //executeSpatialReuse(pRenderContext, renderData);

    //executeUpdateShade(pRenderContext, renderData);

    ++mFrameCount;
}

void RestirInitTemporal::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Direct Light", mDirectLight);
    widget.checkbox("Indirect Light", mIndirectLight);
    widget.checkbox("Temporal Reuse", mTemporalReuse);
    widget.checkbox("Spatial Reuse", mSpatialReuse);

    if(widget.button("Clear Buffers"))
    {
        if (!mClearBuffers)
        {
            mClearBuffers = true;
            mInitLights = true;
        }
    }
}

void RestirInitTemporal::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    mInitLights = true;
    prepareInitSamplesAndTemporalProgram();
    prepareSpatialResamplingAndFinalizeProgram();
    prepareCopyTemporalProgram();

    //prepareInitSamplesProgram();
    //prepareTemporalProgram();
    //prepareSpatialProgram();
    //prepareFinalizeProgram();

    //prepareInitTemporalProgram();
    //prepareSpatialReuseProgram();
    //prepareUpdateShadeProgram();
}

namespace
{
void bindChannels(const ChannelList& channelList, ShaderVar& var, const RenderData& renderData)
{
    for (auto channel : channelList)
    {
        if (!channel.texname.empty() && var.hasMember(channel.texname))
        {
            var[channel.texname] = renderData.getTexture(channel.name);
        }
    }
}
}

void RestirInitTemporal::prepareInitSamplesAndTemporalProgram()
{
    mTracerInit.pProgram = nullptr;
    mTracerInit.pBindingTable = nullptr;
    mTracerInit.pVars = nullptr;
    mInitLights = true;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kInitSamplesShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerInit.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerInit.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setMiss(1, desc.addMiss(kEntryIndirectMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));
        bindingTable->setHitGroup(
            1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup(kEntryIndirectClosestHit, kEntryIndirectAnyHit)
        );

        mTracerInit.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::prepareSpatialResamplingAndFinalizeProgram()
{
    mTracerSpatial.pProgram = nullptr;
    mTracerSpatial.pBindingTable = nullptr;
    mTracerSpatial.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatialShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerSpatial.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerSpatial.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));

        mTracerSpatial.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::prepareCopyTemporalProgram()
{
    mTracerFinalize.pProgram = nullptr;
    mTracerFinalize.pBindingTable = nullptr;
    mTracerFinalize.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kFinalizeShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerFinalize.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerFinalize.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));

        mTracerFinalize.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeInitSamplesAndTemporalProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerInit.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gInitialSamples"] = mInitLights;
    var["CB"]["gEnableTemporal"] = mTemporalReuse;
    var["CB"]["gClearBuffers"] = mClearBuffers;

    bindChannels(kInputChannels, var, renderData);

    var["gTemporalReservoir_DI"] = mpTemporalReservoirOld_DI;
    var["gTemporalReservoir_GI"] = mpTemporalReservoirOld_GI;

    var["gSpatialReservoir_DI"] = mpSpatialReservoir_DI;
    var["gSpatialReservoir_GI"] = mpSpatialReservoir_GI;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerInit.pProgram.get(), mTracerInit.pVars, uint3(targetDim, 1));
    mInitLights = false;
}

void RestirInitTemporal::executeSpatialResamplingAndFinalizeProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerSpatial.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gEnableSpatial"] = mSpatialReuse;

    var["CB"]["gDirectLight"] = mDirectLight;
    var["CB"]["gIndirectLight"] = mIndirectLight;

    var["CB"]["gClearBuffers"] = mClearBuffers;

    bindChannels(kInputChannels, var, renderData);
    bindChannels(kOutputChannels, var, renderData);

    var["gTemporalReservoir_DI"] = mpTemporalReservoirOld_DI;
    var["gTemporalReservoir_GI"] = mpTemporalReservoirOld_GI;

    var["gSpatialReservoir_DI"] = mpSpatialReservoir_DI;
    var["gSpatialReservoir_GI"] = mpSpatialReservoir_GI;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerSpatial.pProgram.get(), mTracerSpatial.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::executeCopyTemporalProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerFinalize.pVars->getRootVar();
    var["CB"]["gClearBuffers"] = mClearBuffers;
    mClearBuffers = false;

    var["gTemporalReservoir_DI"] = mpTemporalReservoirOld_DI;
    var["gSpatialReservoir_DI"] = mpSpatialReservoir_DI;

    var["gTemporalReservoir_GI"] = mpTemporalReservoirOld_GI;
    var["gSpatialReservoir_GI"] = mpSpatialReservoir_GI;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerFinalize.pProgram.get(), mTracerFinalize.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::executeInitSamples(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerInit.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;

    bindChannels(kInputChannels, var, renderData);

    //var["gInitialSamplesReservoir_DI"] = mpInitialSamplesReservoir_DI;
    //var["gInitialSamplesReservoir_GI"] = mpInitialSamplesReservoir_GI;
    var["gDirectLightRadiance"] = mpDirectLightRadiance;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerInit.pProgram.get(), mTracerInit.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::prepareInitSamplesProgram()
{
    mTracerInit.pProgram = nullptr;
    mTracerInit.pBindingTable = nullptr;
    mTracerInit.pVars = nullptr;
    mInitLights = true;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kInitSamplesShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerInit.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerInit.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setMiss(1, desc.addMiss(kEntryIndirectMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));
        bindingTable->setHitGroup(
            1,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup(kEntryIndirectClosestHit, kEntryIndirectAnyHit)
        );

        mTracerInit.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeTemporal(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerTemporal.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gInitialSamples"] = mInitLights;
    var["CB"]["gEnableTemporal"] = mTemporalReuse;

    bindChannels(kInputChannels, var, renderData);

    var["gTemporalReservoirOld_DI"] = mpTemporalReservoirOld_DI;
    //var["gTemporalReservoirNew_DI"] = mpTemporalReservoirNew_DI;
    //var["gInitialSamplesReservoir_DI"] = mpInitialSamplesReservoir_DI;

    var["gTemporalReservoirOld_GI"] = mpTemporalReservoirOld_GI;
    //var["gTemporalReservoirNew_GI"] = mpTemporalReservoirNew_GI;
    //var["gInitialSamplesReservoir_GI"] = mpInitialSamplesReservoir_GI;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerTemporal.pProgram.get(), mTracerTemporal.pVars, uint3(targetDim, 1));
    mInitLights = false;
}

void RestirInitTemporal::prepareTemporalProgram()
{
    mTracerTemporal.pProgram = nullptr;
    mTracerTemporal.pBindingTable = nullptr;
    mTracerTemporal.pVars = nullptr;
    mInitLights = true;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kTemporalShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerTemporal.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerTemporal.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));

        mTracerTemporal.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeSpatial(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerSpatial.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gEnableSpatial"] = mSpatialReuse;

    bindChannels(kInputChannels, var, renderData);

    //var["gTemporalReservoir_DI"] = mpTemporalReservoirNew_DI;
    var["gSpatialReservoir_DI"] = mpSpatialReservoir_DI;

    //var["gTemporalReservoir_GI"] = mpTemporalReservoirNew_GI;
    var["gSpatialReservoir_GI"] = mpSpatialReservoir_GI;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerSpatial.pProgram.get(), mTracerSpatial.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::prepareSpatialProgram()
{
    mTracerSpatial.pProgram = nullptr;
    mTracerSpatial.pBindingTable = nullptr;
    mTracerSpatial.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatialShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerSpatial.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerSpatial.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));

        mTracerSpatial.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeFinalize(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerFinalize.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gDirectLight"] = mDirectLight;
    var["CB"]["gIndirectLight"] = mIndirectLight;

    var["CB"]["gClearBuffers"] = mClearBuffers;
    mClearBuffers = false;

    bindChannels(kInputChannels, var, renderData);
    bindChannels(kOutputChannels, var, renderData);

    var["gTemporalReservoirOld_DI"] = mpTemporalReservoirOld_DI;
    //var["gTemporalReservoirNew_DI"] = mpTemporalReservoirNew_DI;
    var["gSpatialReservoir_DI"] = mpSpatialReservoir_DI;

    var["gTemporalReservoirOld_GI"] = mpTemporalReservoirOld_GI;
    //var["gTemporalReservoirNew_GI"] = mpTemporalReservoirNew_GI;
    var["gSpatialReservoir_GI"] = mpSpatialReservoir_GI;

    var["gDirectLightRadiance"] = mpDirectLightRadiance;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerFinalize.pProgram.get(), mTracerFinalize.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::prepareFinalizeProgram()
{
    mTracerFinalize.pProgram = nullptr;
    mTracerFinalize.pBindingTable = nullptr;
    mTracerFinalize.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kFinalizeShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerFinalize.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerFinalize.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", kEntryShadowAnyHit));

        mTracerFinalize.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::allocateReservoir(uint bufferX, uint bufferY)
{
    bool allocate = mpTemporalReservoirOld_DI == nullptr;
    allocate = allocate || mBufferDim.x != bufferX || mBufferDim.y != bufferY;

    if (allocate)
    {
        mBufferDim = uint2(bufferX, bufferY);
        const uint sampleCount = bufferX * bufferY;

        // Initial samples
        /*{
            ShaderVar var = mTracerInit.pVars->getRootVar();
            mpInitialSamplesReservoir_DI = mpDevice->createStructuredBuffer(
                var["gInitialSamplesReservoir_DI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );

            mpInitialSamplesReservoir_GI = mpDevice->createStructuredBuffer(
                var["gInitialSamplesReservoir_GI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );
        }*/

        // Temporal resources
        {
            //ShaderVar var = mTracerTemporal.pVars->getRootVar();
            ShaderVar var = mTracerInit.pVars->getRootVar();
            mpTemporalReservoirOld_DI = mpDevice->createStructuredBuffer(
                var["gTemporalReservoir_DI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );

           /* mpTemporalReservoirNew_DI = mpDevice->createStructuredBuffer(
                var["gTemporalReservoirNew_DI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );*/

            mpTemporalReservoirOld_GI = mpDevice->createStructuredBuffer(
                var["gTemporalReservoir_GI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );

            /*mpTemporalReservoirNew_GI = mpDevice->createStructuredBuffer(
                var["gTemporalReservoirNew_GI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );*/
        }

        // Spatial resources
        {
            ShaderVar var = mTracerSpatial.pVars->getRootVar();
            mpSpatialReservoir_DI = mpDevice->createStructuredBuffer(
                var["gSpatialReservoir_DI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );

            mpSpatialReservoir_GI = mpDevice->createStructuredBuffer(
                var["gSpatialReservoir_GI"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );
        }

        /*mpDirectLightRadiance = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource
        );

        mpReservoirPrevious = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
        );

        mpReservoirCurrent = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
        );

        mpReservoirSpatial = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
        );*/
    }
}

void RestirInitTemporal::prepareVars()
{
    //const std::vector<PassTrace*> traces({&mTracerTemporal, &mTracerSpatial, &mTracerUpdateShade});
    //const std::vector<PassTrace*> traces({&mTracerInit, &mTracerTemporal, &mTracerSpatial, &mTracerFinalize});
    const std::vector<PassTrace*> traces({&mTracerInit, &mTracerSpatial, &mTracerFinalize});
    for (PassTrace* trace : traces)
    {
        trace->pProgram->addDefines(mpSampleGenerator->getDefines());
        trace->pProgram->setTypeConformances(mpScene->getTypeConformances());

        trace->pVars = RtProgramVars::create(mpDevice, trace->pProgram, trace->pBindingTable);

        ShaderVar var = trace->pVars->getRootVar();
        mpSampleGenerator->bindShaderData(var);
    }
}
