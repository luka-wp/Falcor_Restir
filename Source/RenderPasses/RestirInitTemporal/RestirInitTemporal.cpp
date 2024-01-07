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
const char* kInitTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirMain.rt.slang";
//const char* kInitTemporalShaderFile = "RenderPasses/RestirInitTemporal/RestirInitTemporal.rt.slang";
const char* kSpatialReuseShaderFile = "RenderPasses/RestirInitTemporal/RestirSpatialReuse.rt.slang";
const char* kUpdateShadeShaderFile = "RenderPasses/RestirInitTemporal/RestirUpdateReservoirShade.rt.slang";

const uint32_t kMaxPayloadSizeBytes = 64u;
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

//const ChannelList kTemporalInputChannels = {
//    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
//    {"viewW", "gViewW", "World-space view direction (xyz float format)", true},
//    {"motionVector", "gMotionVector", "Screen space motion vector"}};

const ChannelList kTemporalInputChannels = {
    {kInputPositionWorld, "gPositionW", ""},
    {kInputNormalWorld, "gNormalW", ""},
    {kInputTangentWorld, "gTangentW", ""},
    {kInputDiffuseOpacity, "gDiffuseColor", ""},
    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
};

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
const char* kOutputColor = "outputColor";

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
    addRenderPassInputs(reflector, kTemporalInputChannels);
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
    mTracerTemporal.pProgram->addDefines(getValidResourceDefines(kTemporalInputChannels, renderData));
    mTracerTemporal.pProgram->addDefines(getValidResourceDefines(kTemporalOutputChannels, renderData));

    /*mTracerSpatial.pProgram->addDefines(getValidResourceDefines(kSpatialInputChannels, renderData));
    mTracerSpatial.pProgram->addDefines(getValidResourceDefines(kSpatialOutputChannels, renderData));

    mTracerUpdateShade.pProgram->addDefines(getValidResourceDefines(kUpdateShadeInputChannels, renderData));
    mTracerUpdateShade.pProgram->addDefines(getValidResourceDefines(kUpdateShadeOutputChannels, renderData));*/

    //if (!mTracerTemporal.pVars || !mTracerSpatial.pVars)
    if (!mTracerTemporal.pVars)
    {
        prepareVars();
    }

    const uint2 dims = renderData.getDefaultTextureDims();
    allocateReservoir(dims.x, dims.y);

    executeInitTemporal(pRenderContext, renderData);

    //executeSpatialReuse(pRenderContext, renderData);

    //executeUpdateShade(pRenderContext, renderData);

    ++mFrameCount;
}

void RestirInitTemporal::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Temporal Reuse", mTemporalReuse);
    widget.checkbox("Spatial Reuse", mSpatialReuse);
    widget.checkbox("Indirect Light", mIndirectLight);
}

void RestirInitTemporal::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;

    prepareInitTemporalProgram();
   /* prepareSpatialReuseProgram();
    prepareUpdateShadeProgram();*/
}

namespace
{
void bindChannels(const ChannelList& channelList, ShaderVar& var, const RenderData& renderData)
{
    for (auto channel : channelList)
    {
        if (!channel.texname.empty())
        {
            var[channel.texname] = renderData.getTexture(channel.name);
        }
    }
}
}

void RestirInitTemporal::executeInitTemporal(RenderContext* pRenderContext, const RenderData& renderData)
{
    const float4x4& prevViewMatrix = mpScene->getCamera()->getPrevViewMatrix();

    ShaderVar var = mTracerTemporal.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gInitLights"] = mInitLights;
    var["CB"]["gTemporalReuse"] = mTemporalReuse;
    var["CB"]["gIndirectLight"] = mIndirectLight;
    var["CB"]["gPrevViewMatrix"] = prevViewMatrix;

    bindChannels(kTemporalInputChannels, var, renderData);
    bindChannels(kTemporalOutputChannels, var, renderData);

    /*var["gReservoirPrevious"] = mpReservoirPrevious;
    var["gReservoirCurrent"] = mpReservoirCurrent;*/

    var["gPreviousReservoir"] = mpPreviousReservoir;
    var["gCurrentReservoir"] = mpCurrentReservoir;

    uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerTemporal.pProgram.get(), mTracerTemporal.pVars, uint3(targetDim, 1));
    mInitLights = false;
}

void RestirInitTemporal::prepareInitTemporalProgram()
{
    mTracerTemporal.pProgram = nullptr;
    mTracerTemporal.pBindingTable = nullptr;
    mTracerTemporal.pVars = nullptr;
    mInitLights = true;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kInitTemporalShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerTemporal.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracerTemporal.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setMiss(1, desc.addMiss(kEntryIndirectMiss));
        bindingTable->setHitGroup(
            0,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup("", kEntryShadowAnyHit)
        );
        bindingTable->setHitGroup(
            1,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup(kEntryIndirectClosestHit, kEntryIndirectAnyHit)
        );

        mTracerTemporal.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeSpatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerSpatial.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gSpatialReuse"] = mSpatialReuse;

    bindChannels(kSpatialInputChannels, var, renderData);
    bindChannels(kSpatialOutputChannels, var, renderData);

    var["gReservoirCurrent"] = mpReservoirCurrent;
    var["gReservoirSpatial"] = mpReservoirSpatial;

    const uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerSpatial.pProgram.get(), mTracerSpatial.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::prepareSpatialReuseProgram()
{
    mTracerSpatial.pProgram = nullptr;
    mTracerSpatial.pBindingTable = nullptr;
    mTracerSpatial.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatialReuseShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerSpatial.pBindingTable = RtBindingTable::create(0, 0, mpScene->getGeometryCount());
        ref<RtBindingTable>& bindingTable = mTracerSpatial.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));

        mTracerSpatial.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::executeUpdateShade(RenderContext* pRenderContext, const RenderData& renderData)
{
    ShaderVar var = mTracerUpdateShade.pVars->getRootVar();

    var["CB"]["gFrameCount"] = mFrameCount;

    bindChannels(kUpdateShadeInputChannels, var, renderData);
    bindChannels(kUpdateShadeOutputChannels, var, renderData);

    var["gReservoirPrevious"] = mpReservoirPrevious;
    var["gReservoirSpatial"] = mpReservoirSpatial;

    const uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracerUpdateShade.pProgram.get(), mTracerUpdateShade.pVars, uint3(targetDim, 1));
}

void RestirInitTemporal::prepareUpdateShadeProgram()
{
    mTracerUpdateShade.pProgram = nullptr;
    mTracerUpdateShade.pBindingTable = nullptr;
    mTracerUpdateShade.pVars = nullptr;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kUpdateShadeShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracerUpdateShade.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        ref<RtBindingTable>& bindingTable = mTracerUpdateShade.pBindingTable;
        bindingTable->setRayGen(desc.addRayGen(kEntryRayGen));
        bindingTable->setMiss(0, desc.addMiss(kEntryShadowMiss));
        bindingTable->setHitGroup(
            0,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup("", kEntryShadowAnyHit)
        );

        mTracerUpdateShade.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::allocateReservoir(uint bufferX, uint bufferY)
{
    bool allocate = mpReservoirPrevious == nullptr || mpReservoirCurrent == nullptr;
    allocate = allocate || mpReservoirPrevious->getWidth() != bufferX || mpReservoirPrevious->getHeight() != bufferY;

    if (allocate)
    {
        const uint sampleCount = bufferX * bufferY;
        // Temporal resources
        {
            ShaderVar var = mTracerTemporal.pVars->getRootVar();
            mpPreviousReservoir = mpDevice->createStructuredBuffer(
                var["gPreviousReservoir"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );

            mpCurrentReservoir = mpDevice->createStructuredBuffer(
                var["gCurrentReservoir"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );
        }

        // Spatial resources
        /*{
            ShaderVar var = mTracerSpatial.pVars->getRootVar();
            mpSpatialReservoir = mpDevice->createStructuredBuffer(
                var["gSpatialReservoir"],
                sampleCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                MemoryType::DeviceLocal,
                nullptr,
                false
            );
        }*/

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
        );
    }
}

void RestirInitTemporal::prepareVars()
{
    //const std::vector<PassTrace*> traces({&mTracerTemporal, &mTracerSpatial, &mTracerUpdateShade});
    const std::vector<PassTrace*> traces({&mTracerTemporal});
    for (PassTrace* trace : traces)
    {
        trace->pProgram->addDefines(mpSampleGenerator->getDefines());
        trace->pProgram->setTypeConformances(mpScene->getTypeConformances());

        trace->pVars = RtProgramVars::create(mpDevice, trace->pProgram, trace->pBindingTable);

        ShaderVar var = trace->pVars->getRootVar();
        mpSampleGenerator->bindShaderData(var);
    }
}
