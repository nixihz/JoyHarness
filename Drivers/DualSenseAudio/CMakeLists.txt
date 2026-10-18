cmake_minimum_required(VERSION 3.24)
project(DualSenseAudio C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)
# The integrated driver is currently validated only on macOS 26.
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0 CACHE STRING "" FORCE)
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# Share the pinned portable codec with the app. Clean release runners must not
# depend on an unpinned Homebrew library or on a developer's CMake cache.
set(OPUS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../Vendor/Opus")
file(GLOB_RECURSE OPUS_SOURCES CONFIGURE_DEPENDS
    "${OPUS_ROOT}/src/*.c" "${OPUS_ROOT}/celt/*.c" "${OPUS_ROOT}/silk/*.c")
add_library(ds5opus STATIC ${OPUS_SOURCES})
target_include_directories(ds5opus PUBLIC "${OPUS_ROOT}/include" PRIVATE
    "${OPUS_ROOT}/src" "${OPUS_ROOT}/celt" "${OPUS_ROOT}/silk" "${OPUS_ROOT}/silk/float")
target_compile_definitions(ds5opus PRIVATE OPUS_BUILD VAR_ARRAYS HAVE_LRINT
    HAVE_LRINTF DISABLE_DEBUG_FLOAT ENABLE_HARDENING PACKAGE_VERSION="1.5.2")
set_target_properties(ds5opus PROPERTIES POSITION_INDEPENDENT_CODE ON)

find_library(IOKIT IOKit REQUIRED)
find_library(COREFOUNDATION CoreFoundation REQUIRED)
find_library(COREAUDIO CoreAudio REQUIRED)

# Shared: position-independent shared-memory rings, real-time plug-in port, XPC contract. No IOKit, no Opus.
file(GLOB SHARED_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/shared/*.c)
add_library(ds5shared STATIC ${SHARED_SOURCES})
target_include_directories(ds5shared PUBLIC ${CMAKE_SOURCE_DIR}/src/shared ${CMAKE_SOURCE_DIR}/src/engine)
set_target_properties(ds5shared PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Engine: HID link, report protocol, Opus, pacing. Used by the helper daemon and the CLI.
file(GLOB ENGINE_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/engine/*.c)
add_library(ds5engine STATIC ${ENGINE_SOURCES})
target_include_directories(ds5engine PUBLIC ${CMAKE_SOURCE_DIR}/src/engine)
target_link_libraries(ds5engine PUBLIC ds5shared ds5opus ${IOKIT} ${COREFOUNDATION})
set_target_properties(ds5engine PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Root helper daemon owning the DualSense (coreaudiod's _coreaudiod user may not open HID devices).
file(GLOB DAEMON_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/daemon/*.c)
add_executable(ds5audiod ${DAEMON_SOURCES})
target_link_libraries(ds5audiod PRIVATE ds5engine)

# CoreAudio HAL AudioServerPlugIn bundle: DualSenseAudio.driver (talks to ds5audiod over XPC + shared memory)
file(GLOB PLUGIN_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/plugin/*.c)
add_library(DualSenseAudio MODULE ${PLUGIN_SOURCES})
target_link_libraries(DualSenseAudio PRIVATE ds5shared ${COREAUDIO} ${COREFOUNDATION})
set_target_properties(DualSenseAudio PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION driver
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/src/plugin/Info.plist.in
    MACOSX_BUNDLE_BUNDLE_NAME DualSenseAudio
    MACOSX_BUNDLE_GUI_IDENTIFIER com.psgrok.DualSenseAudio)
add_custom_command(TARGET DualSenseAudio POST_BUILD
    COMMAND codesign --force --sign - $<TARGET_BUNDLE_DIR:DualSenseAudio>
    VERBATIM)

# Diagnostics CLI driving the same engine without CoreAudio.
file(GLOB CLI_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/cli/*.c)
add_executable(ds5audio ${CLI_SOURCES})
target_link_libraries(ds5audio PRIVATE ds5engine)
