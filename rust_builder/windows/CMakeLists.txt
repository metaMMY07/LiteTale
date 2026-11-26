# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_wild")
project(${PROJECT_NAME} LANGUAGES CXX)

# The search fix already ships as a verified native DLL. Reuse it while
# rebuilding the Windows host so adding WebView2 cannot overwrite that fix.
set(rust_lib_wild_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/rust_lib_wild.dll"
  PARENT_SCOPE
)
