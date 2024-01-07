add_plugin(RestirInitTemporal)

target_sources(RestirInitTemporal PRIVATE
    RestirInitTemporal.cpp
    RestirInitTemporal.h
    RestirMain.rt.slang
    RestirInitTemporal.rt.slang
    RestirSpatialReuse.rt.slang
    RestirUpdateReservoirShade.rt.slang
)

target_copy_shaders(RestirInitTemporal RenderPasses/RestirInitTemporal)

target_source_group(RestirInitTemporal "RenderPasses")
