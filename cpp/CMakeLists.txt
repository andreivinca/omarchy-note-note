# The optional native text inspector (see textblocks.h). Build with
# `sh cpp/build.sh`; the module lands in build/NoteNoteText/ where
# ui/NativeBlocks.qml imports it by directory.
cmake_minimum_required(VERSION 3.21)
project(notenotetext LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Qml Quick)

qt_add_qml_module(notenotetext
    URI NoteNoteText
    VERSION 1.0
    PLUGIN_TARGET notenotetext
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/NoteNoteText
    SOURCES textblocks.h textblocks.cpp
)

target_link_libraries(notenotetext PRIVATE Qt6::Quick)
