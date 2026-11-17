cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "virtual_gamepad.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# ViGEmClient (MIT) for virtual Xbox controllers. Only the source is fetched;
# its own CMake install rules are skipped so nothing extra lands in the bundle.
include(FetchContent)
FetchContent_Declare(vigemclient
  GIT_REPOSITORY https://github.com/nefarius/ViGEmClient.git
  GIT_TAG b66d02d57e32cc8595369c53418b843e958649b4
  SOURCE_SUBDIR do-not-add-subdirectory)
FetchContent_MakeAvailable(vigemclient)
add_library(lv_vigemclient STATIC "${vigemclient_SOURCE_DIR}/src/ViGEmClient.cpp")
target_include_directories(lv_vigemclient PUBLIC "${vigemclient_SOURCE_DIR}/include"
                                          PRIVATE "${vigemclient_SOURCE_DIR}/src")
target_compile_definitions(lv_vigemclient PRIVATE UNICODE _UNICODE)
target_link_libraries(lv_vigemclient PUBLIC setupapi.lib)
target_link_libraries(${BINARY_NAME} PRIVATE lv_vigemclient)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
