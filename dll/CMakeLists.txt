cmake_minimum_required(VERSION 3.24)

project(flataim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)
FetchContent_Declare(
    minhook
    GIT_REPOSITORY https://github.com/TsudaKageyu/minhook.git
    GIT_TAG v1.3.4
)
FetchContent_MakeAvailable(minhook)

add_library(FlatAim SHARED FlatAim.cpp)
target_compile_definitions(FlatAim PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(FlatAim PRIVATE minhook user32)
set_target_properties(FlatAim PROPERTIES OUTPUT_NAME "FlatAim")
