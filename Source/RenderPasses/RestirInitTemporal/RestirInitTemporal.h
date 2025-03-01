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
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

using namespace Falcor;

class RestirInitTemporal : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(RestirInitTemporal, "RestirInitTemporal", "Insert pass description here.");

    static ref<RestirInitTemporal> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<RestirInitTemporal>(pDevice, props);
    }

    RestirInitTemporal(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    struct PassTrace
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    };

    /* >> ReSTIR 3 >>*/
    void prepareInitSamplesAndTemporalProgram();
    void prepareSpatialResamplingAndFinalizeProgram();
    void prepareCopyTemporalProgram();

    void executeInitSamplesAndTemporalProgram(RenderContext* pRenderContext, const RenderData& renderData);
    void executeSpatialResamplingAndFinalizeProgram(RenderContext* pRenderContext, const RenderData& renderData);
    void executeCopyTemporalProgram(RenderContext* pRenderContext, const RenderData& renderData);

    void executeInitSamples(RenderContext* pRenderContext, const RenderData& renderData);
    void prepareInitSamplesProgram();

    void executeTemporal(RenderContext* pRenderContext, const RenderData& renderData);
    void prepareTemporalProgram();

    void executeSpatial(RenderContext* pRenderContext, const RenderData& renderData);
    void prepareSpatialProgram();

    void executeFinalize(RenderContext* pRenderContext, const RenderData& renderData);
    void prepareFinalizeProgram();
    /* << ReSTIR 3 <<*/

    void allocateReservoir(uint bufferX, uint bufferY);
    void prepareVars();

    bool mClearBuffers = false;

    bool mInitLights = true;
    bool mTemporalReuse = true;
    bool mSpatialReuse = true;
    bool mDirectLight = true;
    bool mIndirectLight = true;
    uint mFrameCount = 0;

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;

    ref<Texture> mpDirectLightRadiance;

    // >> Direct Illumination >> //
    //ref<Buffer> mpInitialSamplesReservoir_DI;
    ref<Buffer> mpTemporalReservoirOld_DI;
    //ref<Buffer> mpTemporalReservoirNew_DI;
    ref<Buffer> mpSpatialReservoir_DI;
    // << Direct Illumination << //

    // >> Global Illumination >> //
    //ref<Buffer> mpInitialSamplesReservoir_GI;
    ref<Buffer> mpTemporalReservoirOld_GI;
    //ref<Buffer> mpTemporalReservoirNew_GI;
    ref<Buffer> mpSpatialReservoir_GI;
    // << Global Illumination << //


    //PassTrace mTracerTemporal;
    //PassTrace mTracerSpatial;
    PassTrace mTracerUpdateShade;

    /* >> ReSTIR 3 >>*/
    uint2 mBufferDim = uint2(0, 0);
    ref<Texture> mpReservoirPrevious;
    ref<Texture> mpReservoirCurrent;
    ref<Texture> mpReservoirSpatial;

    PassTrace mTracerInit;
    PassTrace mTracerTemporal;
    PassTrace mTracerSpatial;
    PassTrace mTracerFinalize;

    /* << ReSTIR 3 <<*/
};
