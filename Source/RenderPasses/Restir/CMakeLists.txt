add_plugin(Restir)

target_sources(Restir PRIVATE
    Restir.cpp
    Restir.h
    Restir.slang
    Restir.rt.slang
)

target_copy_shaders(Restir RenderPasses/Restir)

target_source_group(Restir "RenderPasses")
