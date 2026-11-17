cmake_minimum_required(VERSION 3.20)
project(driver_localview LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(openvr
  GIT_REPOSITORY https://github.com/ValveSoftware/openvr.git
  GIT_TAG 0924064316de3effbcd1acf1e309182a2deb1c05
  GIT_SHALLOW FALSE
  SOURCE_SUBDIR do-not-add-subdirectory)
FetchContent_MakeAvailable(openvr)

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
