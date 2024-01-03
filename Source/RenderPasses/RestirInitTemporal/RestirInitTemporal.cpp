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
const char* kShaderFile = "RenderPasses/RestirInitTemporal/RestirInitTemporal.rt.slang";

const uint32_t kMaxPayloadSizeBytes = 72u;
const uint32_t kMaxRecursionDepth = 2u;

const char* kEntryRayGen = "rayGen";

const char* kEntryShadowMiss = "shadowMiss";
const char* kEntryShadowAnyHit = "shadowAnyHit";
const char* kEntryShadowClosestHit = "shadowClosestHit";

const char* kEntryIndirectMiss = "indirectMiss";
const char* kEntryIndirectAnyHit = "indirectAnyHit";
const char* kEntryIndirectClosestHit = "indirectClosestHit";

const ChannelList kInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
    {"viewW", "gViewW", "World-space view direction (xyz float format)", true},
    {"motionVector", "gMotionVector", "Screen space motion vector"}};


const char* kReservoirCurrent = "reservoirCurrent";
const char* kReservoirPrevious = "reservoirPrevious";
const ChannelList kOutputChannels = {
    {kReservoirCurrent, "gReservoirCurrent", "Current reservoir state"},
    {kReservoirPrevious, "gReservoirPrevious", "Previous reservoir state"}
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
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void RestirInitTemporal::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        for (auto it : kOutputChannels)
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

    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mTracer.pVars)
    {
        prepareVars();
    }

    ShaderVar var = mTracer.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gInitLights"] = mInitLights;

    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);

    mInitLights = false;
    ++mFrameCount;
}

void RestirInitTemporal::renderUI(Gui::Widgets& widget)
{
}

void RestirInitTemporal::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;

    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;
    mInitLights = true;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile);

        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());

        mTracer.pBindingTable = RtBindingTable::create(
            2,
            2,
            mpScene->getGeometryCount());

        ref<RtBindingTable>& bindingTable = mTracer.pBindingTable;
        bindingTable->setRayGen(
            desc.addRayGen(kEntryRayGen)
        );
        bindingTable->setMiss(
            0,
            desc.addMiss(kEntryShadowMiss)
        );
        bindingTable->setMiss(
            1,
            desc.addMiss(kEntryIndirectMiss)
        );
        bindingTable->setHitGroup(
            0,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup(kEntryShadowClosestHit, kEntryShadowAnyHit)
        );
        bindingTable->setHitGroup(
            1,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup(kEntryIndirectClosestHit, kEntryIndirectAnyHit)
        );

        mTracer.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void RestirInitTemporal::allocateReservoir(int bufferX, int bufferY)
{
    bool allocate = mpReservoirPrevious == nullptr || mpReservoirCurrent == nullptr;
    allocate = allocate || mpReservoirPrevious->getWidth() != bufferX || mpReservoirPrevious->getHeight() != bufferY;

    if (allocate)
    {
        mpReservoirPrevious = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess
        );

        mpReservoirCurrent = mpDevice->createTexture2D(
            bufferX,
            bufferY,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::UnorderedAccess
        );
    }
}

void RestirInitTemporal::prepareVars()
{
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);

    ShaderVar var = mTracer.pVars->getRootVar();
    mpSampleGenerator->bindShaderData(var);
}
