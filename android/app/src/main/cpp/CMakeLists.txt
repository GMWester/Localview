cmake_minimum_required(VERSION 3.22.1)
project(localview_vr LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(OpenXR REQUIRED CONFIG)

add_library(native_app_glue STATIC ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)
target_include_directories(native_app_glue PUBLIC ${ANDROID_NDK}/sources/android/native_app_glue)

add_library(localview_vr SHARED vr_main.cpp)
target_include_directories(localview_vr PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../vr/common)
set_target_properties(localview_vr PROPERTIES LINK_FLAGS "-u ANativeActivity_onCreate")
target_compile_options(localview_vr PRIVATE -O2 -Wall)
target_link_libraries(localview_vr PRIVATE native_app_glue OpenXR::openxr_loader android log EGL GLESv3 mediandk)
