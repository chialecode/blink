cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Read optional build-time metadata directly from environment variables (never
# cached) so packaging can inject channel, version, and icon resources without
# mutating any tracked git files.
if(DEFINED ENV{BLINK_PRODUCT_VERSION} AND NOT "$ENV{BLINK_PRODUCT_VERSION}" STREQUAL "")
  set(BLINK_PRODUCT_VERSION "$ENV{BLINK_PRODUCT_VERSION}")
else()
  set(BLINK_PRODUCT_VERSION "0.1.0-dev.local")
endif()

if(DEFINED ENV{BLINK_FILE_VERSION} AND NOT "$ENV{BLINK_FILE_VERSION}" STREQUAL "")
  set(BLINK_FILE_VERSION "$ENV{BLINK_FILE_VERSION}")
else()
  set(BLINK_FILE_VERSION "0,1,0,0")
endif()

if(DEFINED ENV{BLINK_FILE_VERSION_STR} AND NOT "$ENV{BLINK_FILE_VERSION_STR}" STREQUAL "")
  set(BLINK_FILE_VERSION_STR "$ENV{BLINK_FILE_VERSION_STR}")
else()
  set(BLINK_FILE_VERSION_STR "0.1.0.0")
endif()

if(DEFINED ENV{BLINK_PRODUCT_NAME} AND NOT "$ENV{BLINK_PRODUCT_NAME}" STREQUAL "")
  set(BLINK_PRODUCT_NAME "$ENV{BLINK_PRODUCT_NAME}")
else()
  set(BLINK_PRODUCT_NAME "BLINK Dev")
endif()

if(DEFINED ENV{BLINK_FILE_DESCRIPTION} AND NOT "$ENV{BLINK_FILE_DESCRIPTION}" STREQUAL "")
  set(BLINK_FILE_DESCRIPTION "$ENV{BLINK_FILE_DESCRIPTION}")
else()
  set(BLINK_FILE_DESCRIPTION "BLINK Desktop Client")
endif()

if(DEFINED ENV{BLINK_INTERNAL_NAME} AND NOT "$ENV{BLINK_INTERNAL_NAME}" STREQUAL "")
  set(BLINK_INTERNAL_NAME "$ENV{BLINK_INTERNAL_NAME}")
else()
  set(BLINK_INTERNAL_NAME "blink-dev")
endif()

if(DEFINED ENV{BLINK_ORIGINAL_FILENAME} AND NOT "$ENV{BLINK_ORIGINAL_FILENAME}" STREQUAL "")
  set(BLINK_ORIGINAL_FILENAME "$ENV{BLINK_ORIGINAL_FILENAME}")
else()
  set(BLINK_ORIGINAL_FILENAME "blink-dev.exe")
endif()

if(DEFINED ENV{BLINK_ICON_FILE} AND NOT "$ENV{BLINK_ICON_FILE}" STREQUAL "")
  set(BLINK_ICON_FILE "$ENV{BLINK_ICON_FILE}")
else()
  set(BLINK_ICON_FILE "app_icon.ico")
endif()

set(BLINK_VERSION_HEADER "${CMAKE_CURRENT_BINARY_DIR}/blink_version.h")
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/blink_version.h.in"
  "${BLINK_VERSION_HEADER}"
  @ONLY
)

set_source_files_properties("Runner.rc" PROPERTIES
  OBJECT_DEPENDS "${BLINK_VERSION_HEADER};${CMAKE_CURRENT_SOURCE_DIR}/resources/${BLINK_ICON_FILE}"
)
set_source_files_properties("main.cpp" PROPERTIES
  OBJECT_DEPENDS "${BLINK_VERSION_HEADER}"
)

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
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
