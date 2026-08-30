if (DOSBOX_OHOS_EMBED)
  # The host GUI frontend (SDL event pump, window management, clipboard,
  # titlebar) is implemented by the embedding application; it also decides
  # which render backend to instantiate. The input mapper and the render
  # pipeline stay part of the engine.
  target_sources(dosboxcommon PRIVATE
    clipboard.cpp
    mapper.cpp
    titlebar.cpp

    render/auto_image_adjustments.cpp
    render/auto_shader_switcher.cpp
    render/deinterlacer.cpp
    render/opengl_renderer.cpp
    render/render.cpp
    render/scaler/scalers.cpp
    render/sdl_renderer.cpp
    render/shader.cpp
    render/shader_manager.cpp
    render/shader_pipeline.cpp
    render/shader_pragma_parser.cpp
  )
else()
  target_sources(dosboxcommon PRIVATE
    clipboard.cpp
    mapper.cpp
    sdl_gui.cpp
    titlebar.cpp

    render/auto_image_adjustments.cpp
    render/auto_shader_switcher.cpp
    render/deinterlacer.cpp
    render/opengl_renderer.cpp
    render/render.cpp
    render/scaler/scalers.cpp
    render/sdl_renderer.cpp
    render/shader.cpp
    render/shader_manager.cpp
    render/shader_pipeline.cpp
    render/shader_pragma_parser.cpp
  )
endif()

if(APPLE)
target_sources(dosboxcommon PRIVATE
  render/macos_colorspace.mm
)
endif()

if (OPT_DEBUGGER)
  target_link_libraries(dosboxcommon PRIVATE imgui::imgui)
endif()

if (C_OPENGL)
  target_link_libraries(dosboxcommon PRIVATE OpenGL::GL)
endif()

# glad's headers are included unconditionally by the shader pipeline
# headers (even when C_OPENGL is off), so the vendored target must be
# on the include path in every configuration.
target_link_libraries(dosboxcommon PRIVATE glad simpleini)
