cmake_minimum_required(VERSION 3.20)
project(driver_localview LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(openvr
  GIT_REPOSITORY https://github.com/ValveSoftware/openvr.git
  GIT_TAG 0924064316de3effbcd1acf1e309182a2deb1c05
  GIT_SHALLOW FALSE
  SOURCE_SUBDIR do-not-add-subdirectory)
FetchContent_MakeAvailable(openvr)

if(WIN32)
  add_library(driver_localview SHARED
    src/driver_main.cpp
    src/devices.h
    src/session.cpp
    src/network.cpp
    src/hmd.cpp
    src/controller.cpp
    src/compositor.cpp
    src/encoder.cpp)
  target_include_directories(driver_localview PRIVATE "${openvr_SOURCE_DIR}/headers" "${CMAKE_CURRENT_SOURCE_DIR}/../common")
  target_compile_definitions(driver_localview PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_link_libraries(driver_localview PRIVATE d3d11 dxgi d3dcompiler mfplat mf mfuuid ws2_32 shell32 ole32 oleaut32 strmiids)
  set_target_properties(driver_localview PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/localview/bin/win64"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/localview/bin/win64")
  if(MSVC)
    target_compile_options(driver_localview PRIVATE /W3 /EHsc /O2)
  endif()
else()
  # Linux / SteamOS: the driver plus the capture layer and DRM-lease shim that run
  # inside SteamVR's compositor (vr/linux, based on ALVR).
  find_package(Vulkan REQUIRED)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(UNWIND REQUIRED libunwind)
  pkg_check_modules(DRM REQUIRED libdrm)
  find_program(GLSLANG glslangValidator REQUIRED)
  set(LV_LINUX "${CMAKE_CURRENT_SOURCE_DIR}/../linux")
  set(LV_GEN "${CMAKE_CURRENT_BINARY_DIR}/gen")
  file(MAKE_DIRECTORY "${LV_GEN}")
  add_custom_command(
    OUTPUT "${LV_GEN}/rgb_to_nv12.spv.h"
    COMMAND "${GLSLANG}" -V --target-env vulkan1.1 --vn kRgbToNv12 -o "${LV_GEN}/rgb_to_nv12.spv.h"
            "${CMAKE_CURRENT_SOURCE_DIR}/src/linux/rgb_to_nv12.comp"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/linux/rgb_to_nv12.comp")

  set(LV_OUT "${CMAKE_CURRENT_SOURCE_DIR}/localview/bin/linux64")
  add_library(driver_localview SHARED
    src/driver_main.cpp
    src/session.cpp
    src/network.cpp
    src/hmd.cpp
    src/controller.cpp
    src/linux/capture_linux.cpp
    src/linux/encoder_linux.cpp
    "${LV_GEN}/rgb_to_nv12.spv.h")
  target_include_directories(driver_localview PRIVATE "${openvr_SOURCE_DIR}/headers"
    "${CMAKE_CURRENT_SOURCE_DIR}/../common" "${LV_LINUX}" "${LV_GEN}")
  target_compile_options(driver_localview PRIVATE -O2 -fvisibility=hidden -Wall -Wno-unused-parameter -Wno-missing-field-initializers)
  target_link_libraries(driver_localview PRIVATE Vulkan::Vulkan pthread -static-libstdc++ -static-libgcc)
  target_link_options(driver_localview PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)
  set_target_properties(driver_localview PROPERTIES PREFIX "" LIBRARY_OUTPUT_DIRECTORY "${LV_OUT}")

  file(GLOB_RECURSE LV_LAYER_SOURCES "${LV_LINUX}/layer/*.cpp")
  add_library(localview_vk_capture SHARED ${LV_LAYER_SOURCES})
  target_include_directories(localview_vk_capture PRIVATE "${LV_LINUX}/layer" "${LV_LINUX}" ${UNWIND_INCLUDE_DIRS})
  target_compile_definitions(localview_vk_capture PRIVATE VK_USE_PLATFORM_XLIB_XRANDR_EXT)
  target_compile_options(localview_vk_capture PRIVATE -O2 -fvisibility=hidden -Wno-unused-parameter -Wno-missing-field-initializers)
  target_link_libraries(localview_vk_capture PRIVATE ${UNWIND_LINK_LIBRARIES} pthread -static-libstdc++ -static-libgcc)
  # libunwind ships next to the layer (SteamOS does not always have it); $ORIGIN finds it.
  set_target_properties(localview_vk_capture PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
  find_library(UNWIND_SO NAMES libunwind.so.8 unwind REQUIRED)
  file(REAL_PATH "${UNWIND_SO}" UNWIND_SO_REAL)
  add_custom_command(TARGET localview_vk_capture POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy "${UNWIND_SO_REAL}" "${LV_OUT}/libunwind.so.8")
  target_link_options(localview_vk_capture PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)
  set_target_properties(localview_vk_capture PROPERTIES PREFIX "lib" LIBRARY_OUTPUT_DIRECTORY "${LV_OUT}")

  add_library(localview_drm_lease_shim SHARED "${LV_LINUX}/shim/drm-lease-shim.cpp")
  target_include_directories(localview_drm_lease_shim PRIVATE "${LV_LINUX}" ${DRM_INCLUDE_DIRS})
  target_compile_options(localview_drm_lease_shim PRIVATE -O2)
  target_link_libraries(localview_drm_lease_shim PRIVATE dl -static-libstdc++ -static-libgcc)
  target_link_options(localview_drm_lease_shim PRIVATE -Wl,--exclude-libs,ALL)
  set_target_properties(localview_drm_lease_shim PROPERTIES PREFIX "lib" LIBRARY_OUTPUT_DIRECTORY "${LV_OUT}")
endif()

# Linux frame-path test (fake compositor -> import -> NV12 -> ffmpeg), runs on lavapipe.
if(NOT WIN32 AND LV_BUILD_TESTS)
  add_executable(lv_pipeline_test "${LV_LINUX}/test/pipeline_test.cpp" src/linux/capture_linux.cpp
    src/linux/encoder_linux.cpp "${LV_GEN}/rgb_to_nv12.spv.h")
  target_include_directories(lv_pipeline_test PRIVATE "${openvr_SOURCE_DIR}/headers" "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../common" "${LV_LINUX}" "${LV_GEN}")
  target_compile_definitions(lv_pipeline_test PRIVATE LV_NO_STEAMVR)
  target_link_libraries(lv_pipeline_test PRIVATE Vulkan::Vulkan pthread)
endif()
