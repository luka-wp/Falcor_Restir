add_plugin(RestirSpatialReuse)

target_sources(RestirSpatialReuse PRIVATE
    RestirSpatialReuse.cpp
    RestirSpatialReuse.h
)

target_source_group(RestirSpatialReuse "RenderPasses")
