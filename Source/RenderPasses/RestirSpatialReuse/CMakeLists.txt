add_plugin(RestirSpatialReuse)

target_sources(RestirSpatialReuse PRIVATE
    RestirSpatialReuse.cpp
    RestirSpatialReuse.h
    RestirSpatialReuse.rt.slang
)

target_copy_shaders(RestirSpatialReuse RenderPasses/RestirSpatialReuse)

target_source_group(RestirSpatialReuse "RenderPasses")
