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
#include "Restir.h"

#include "Core/API/RasterizerState.h"
#include "Core/Pass/RasterPass.h"
#include "RenderGraph/RenderPassHelpers.h"

namespace
{
//const char* kShaderFileName = "RenderPasses/Restir/Restir.slang";
const char* kRtShaderFile = "RenderPasses/Restir/Restir.rt.slang";

const uint32_t kMaxPayloadSizeBytes = 72u;
const uint32_t kMaxRecursionDepth = 2u;

const ChannelList kInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
    {"viewW", "gViewW", "World-space view direction (xyz float format)", true}
};

const ChannelList kOutputChannels = {{"color", "gOutputColor", "Output color", false, ResourceFormat::RGBA32Float}};
}; // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, Restir>();
}

Restir::Restir(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    parseProperties(props);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties Restir::getProperties() const
{
    Properties props;
    return props;
}

RenderPassReflection Restir::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void Restir::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    //mTracer.pProgram->addDefine("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    //mTracer.pProgram->addDefine("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mTracer.pVars)
    {
        prepareVars();
    }

    ShaderVar var = mTracer.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;

    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
    {
        bind(channel);
    }
    for (auto channel : kOutputChannels)
    {
        bind(channel);
    }

    const uint2 targetDim = renderData.getDefaultTextureDims();
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

    ++mFrameCount;
}

void Restir::renderUI(Gui::Widgets& widget)
{
}

void Restir::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;

    mpScene = pScene;

    if (mpScene)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kRtShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        //desc.setMaxTraceRecursionDepth()

        mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        ref<RtBindingTable>& sbt = mTracer.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("scatterMiss"));
        sbt->setMiss(1, desc.addMiss("shadowMiss"));

        sbt->setHitGroup(
            0,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit")
        );
        sbt->setHitGroup(
            1,
            mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
            desc.addHitGroup("", "shadowTriangleMeshAnyHit"));

        mTracer.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    /*if (!mpProgram)
    {
        ProgramDesc desc;
        desc.addShaderLibrary(kShaderFileName).vsEntry("vsMain").psEntry("psMain");
        desc.setShaderModel(ShaderModel::SM6_1);
        mpProgram = Program::create(mpDevice, desc);

        RasterizerState::Desc wireframeDesc;
        wireframeDesc.setFillMode(RasterizerState::FillMode::Wireframe);
        wireframeDesc.setCullMode(RasterizerState::CullMode::None);
        wireframeDesc.setScissorTest(true);
        mpRasterizerState = RasterizerState::create(wireframeDesc);

        mpGraphicsState = GraphicsState::create(mpDevice);
        mpGraphicsState->setProgram(mpProgram);
        mpGraphicsState->setRasterizerState(mpRasterizerState);
    }

    mpScene = pScene;
    if (mpScene)
    {
        mpProgram->addDefines(mpScene->getSceneDefines());
    }
    mpVars = ProgramVars::create(mpDevice, mpProgram->getReflector());*/
}

void Restir::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
    }
}

void Restir::prepareVars()
{
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);

    ShaderVar var = mTracer.pVars->getRootVar();
    mpSampleGenerator->bindShaderData(var);
}
