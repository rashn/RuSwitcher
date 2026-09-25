cmake_minimum_required(VERSION 3.24)
project(RuSwitcherNative LANGUAGES CXX)

set(RUSWITCHER_VERSION "0.10.0-beta.1" CACHE STRING "Display version embedded in RuSwitcher.exe")
set(RUSWITCHER_VERSION_NUMERIC "0.10.0.1" CACHE STRING "Four-part numeric Windows version")

if(NOT RUSWITCHER_VERSION_NUMERIC MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "RUSWITCHER_VERSION_NUMERIC must contain four numeric components")
endif()

string(REPLACE "." "," RUSWITCHER_VERSION_COMMA "${RUSWITCHER_VERSION_NUMERIC}")
if(RUSWITCHER_VERSION MATCHES "-")
    set(RUSWITCHER_FILE_FLAGS "VS_FF_PRERELEASE")
else()
    set(RUSWITCHER_FILE_FLAGS "0x0L")
endif()
set(RUSWITCHER_ICON_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../src/RuSwitcher.Win/Assets/RuSwitcher.ico")
configure_file(src/resources.rc.in generated/resources.rc @ONLY)

add_executable(RuSwitcherNative WIN32
    src/main.cpp
    src/engine.cpp
    src/clipboard.cpp
    src/diagnostics.cpp
    src/input_safety.cpp
    src/settings.cpp
    src/tray.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/resources.rc
)

target_compile_features(RuSwitcherNative PRIVATE cxx_std_20)
target_compile_definitions(RuSwitcherNative PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(RuSwitcherNative PRIVATE user32 shell32 advapi32 ole32 urlmon uiautomationcore)

if(MSVC)
    target_compile_options(RuSwitcherNative PRIVATE /O1 /Os /GL /Gy /Gw /utf-8 /permissive- /W4)
    target_link_options(RuSwitcherNative PRIVATE /LTCG /OPT:REF /OPT:ICF /INCREMENTAL:NO)
endif()

set_target_properties(RuSwitcherNative PROPERTIES
    OUTPUT_NAME RuSwitcher
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
)
