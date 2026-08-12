cmake_minimum_required(VERSION 3.24)
project(RuSwitcherNative LANGUAGES CXX)

add_executable(RuSwitcherNative WIN32
    src/main.cpp
    src/engine.cpp
    src/input_safety.cpp
)

target_compile_features(RuSwitcherNative PRIVATE cxx_std_20)
target_compile_definitions(RuSwitcherNative PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(RuSwitcherNative PRIVATE user32 ole32 uiautomationcore)

if(MSVC)
    target_compile_options(RuSwitcherNative PRIVATE /O1 /Os /GL /Gy /Gw /permissive- /W4)
    target_link_options(RuSwitcherNative PRIVATE /LTCG /OPT:REF /OPT:ICF /INCREMENTAL:NO)
endif()

set_target_properties(RuSwitcherNative PROPERTIES
    OUTPUT_NAME RuSwitcher
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
)
