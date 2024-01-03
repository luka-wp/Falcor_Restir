add_plugin(RestirUpdateReservoirShade)

target_sources(RestirUpdateReservoirShade PRIVATE
    RestirUpdateReservoirShade.cpp
    RestirUpdateReservoirShade.h
    RestirUpdateReservoirShade.rt.slang
)

target_copy_shaders(RestirUpdateReservoirShade RenderPasses/RestirUpdateReservoirShade)

target_source_group(RestirUpdateReservoirShade "RenderPasses")
