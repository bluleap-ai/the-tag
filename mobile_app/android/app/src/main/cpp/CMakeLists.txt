cmake_minimum_required(VERSION 3.18)
project(lc3_decoder_bridge C)

# Path to liblc3 source (relative to this CMakeLists.txt)
set(LC3_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../modules/lib/liblc3")

# Collect all liblc3 C sources
file(GLOB LC3_SOURCES "${LC3_ROOT}/src/*.c")

add_library(lc3_decoder SHARED
    lc3_decoder_bridge.c
    ${LC3_SOURCES}
)

target_include_directories(lc3_decoder PRIVATE
    "${LC3_ROOT}/include"
    "${LC3_ROOT}/src"
)

# liblc3 needs math library
target_link_libraries(lc3_decoder m)

# Optimise for size on release
target_compile_options(lc3_decoder PRIVATE
    -O2 -fvisibility=hidden
)
