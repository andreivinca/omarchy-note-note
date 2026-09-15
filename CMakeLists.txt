cmake_minimum_required(VERSION 3.21)
project(NoteNote VERSION 1.0.21 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
include(GNUInstallDirs)
include(CTest)
find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 Network DBus)
configure_file(packaging/build-info.json.in note-note-build.json @ONLY)
file(RELATIVE_PATH NOTE_NOTE_DATA_FROM_BIN "${CMAKE_INSTALL_FULL_BINDIR}" "${CMAKE_INSTALL_FULL_DATADIR}/note-note")

add_library(note-note-theme STATIC
    services/theme/palette.cpp services/theme/palette.h
    services/theme/portalsettings.cpp services/theme/portalsettings.h
    services/theme/desktoptheme.cpp services/theme/desktoptheme.h)
target_link_libraries(note-note-theme PUBLIC Qt6::Gui Qt6::DBus)

add_executable(note-note
    hosts/standalone/main.cpp
    hosts/standalone/runtime.cpp hosts/standalone/runtime.h
    hosts/standalone/processbackend.cpp hosts/standalone/processbackend.h
    cpp/textblocks.cpp cpp/textblocks.h cpp/textlinks.cpp cpp/textlinks.h
)
target_link_libraries(note-note PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network note-note-theme)
target_compile_definitions(note-note PRIVATE
    NOTE_NOTE_VERSION="${PROJECT_VERSION}"
    NOTE_NOTE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    NOTE_NOTE_BUILD_DIR="${CMAKE_CURRENT_BINARY_DIR}"
    NOTE_NOTE_DATA_FROM_BIN="${NOTE_NOTE_DATA_FROM_BIN}"
    NOTE_NOTE_INSTALL_DATA_DIR="${CMAKE_INSTALL_FULL_DATADIR}/note-note"
)
install(TARGETS note-note RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES Workspace.qml LICENSE NOTICE.md DESTINATION ${CMAKE_INSTALL_DATADIR}/note-note)
install(DIRECTORY assets design ui providers services lib
    DESTINATION ${CMAKE_INSTALL_DATADIR}/note-note
    PATTERN "__pycache__" EXCLUDE PATTERN "*.pyc" EXCLUDE PATTERN "graphify-out" EXCLUDE
    PATTERN "*selftest*" EXCLUDE)
install(DIRECTORY hosts/standalone DESTINATION ${CMAKE_INSTALL_DATADIR}/note-note/hosts
    FILES_MATCHING PATTERN "*.qml")
install(FILES packaging/io.github.andreivinca.note-note.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES packaging/io.github.andreivinca.note-note.metainfo.xml DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
install(FILES packaging/io.github.andreivinca.note-note.svg DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)

if(BUILD_TESTING)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Test)
    find_program(DBUS_RUN_SESSION dbus-run-session REQUIRED)
    add_executable(theme-test tests/theme_test.cpp)
    target_link_libraries(theme-test PRIVATE Qt6::Test note-note-theme)
    add_test(NAME theme COMMAND ${DBUS_RUN_SESSION} -- $<TARGET_FILE:theme-test>)
    set_tests_properties(theme PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=generic" TIMEOUT 60)
    add_executable(native-runtime-test tests/native_runtime_test.cpp
        hosts/standalone/runtime.cpp hosts/standalone/runtime.h)
    target_link_libraries(native-runtime-test PRIVATE Qt6::Test Qt6::Gui)
    add_test(NAME native-runtime COMMAND native-runtime-test)
    set_tests_properties(native-runtime PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=generic")
    add_test(NAME standalone COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/standalone_selftest.py $<TARGET_FILE:note-note>)
    add_test(NAME native-transitions COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/transition_selftest.py --standalone)
    set_tests_properties(native-transitions PROPERTIES
        ENVIRONMENT "NOTE_NOTE_BINARY=$<TARGET_FILE:note-note>" TIMEOUT 240)
endif()
