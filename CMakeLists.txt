# SPDX-License-Identifier: Apache-2.0

# Build a Zig project as an external project.  The build is done using
# zig build-obj, which will build the project into a single object
# file containing the entire Zig part of the program.  We then
# incorporate that into the Zephyr build.  Main is implemented in Zig.

cmake_minimum_required(VERSION 3.13.1)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

# zephyr_library_import(standalone
#      /home/davidb/linaro/embed-rust/target/thumbv7m-none-eabi/release/libstandalone.a)

project(hello_world)

target_sources(app PRIVATE src/empty.c)
# target_link_libraries(app
#     /home/davidb/linaro/embed-rust/target/thumbv7m-none-eabi/release/libstandalone.a)
# target_link_libraries(app standalone)

include(ExternalProject)

set(standalone_src_dir ${CMAKE_CURRENT_SOURCE_DIR})
set(standalone_build_dir ${standalone_src_dir})

ExternalProject_Add(
    standalone_project
    PREFIX ${standalone_build_dir}
    SOURCE_DIR ${standalone_src_dir}
    BINARY_DIR ${standalone_src_dir}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND "zig" "build-obj"
      # "-OReleaseSmall"
      "-ODebug"
      "-target" "arm-freestanding-eabi" "-mcpu" "cortex_m33" "main.zig"
    INSTALL_COMMAND ""
    BUILD_ALWAYS True
    BUILD_BYPRODUCTS
      ${standalone_build_dir}/main.o)

add_library(standalone_lib STATIC IMPORTED GLOBAL)

# Skip the dependency for now, since the build environment is very
# different.
add_dependencies(
    standalone_lib
    standalone_project
    )
set_target_properties(standalone_lib PROPERTIES IMPORTED_LOCATION
    ${standalone_build_dir}/main.o)

target_link_libraries(app PUBLIC standalone_lib)
