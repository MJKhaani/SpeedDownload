cmake_minimum_required(VERSION 3.20)
project(SpeedDownloadGtk VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
pkg_check_modules(JSON_GLIB REQUIRED IMPORTED_TARGET json-glib-1.0)

add_executable(speed-download-gtk src/main.c)
target_link_libraries(speed-download-gtk PRIVATE PkgConfig::GTK4 PkgConfig::JSON_GLIB)
target_compile_options(speed-download-gtk PRIVATE -Wall -Wextra -Wpedantic)
install(TARGETS speed-download-gtk RUNTIME DESTINATION bin)
install(FILES ../../Resources/icons/hicolor/256x256/apps/org.speeddownload.SpeedDownload.png
        DESTINATION share/icons/hicolor/256x256/apps)
install(FILES ../../Resources/icons/hicolor/512x512/apps/org.speeddownload.SpeedDownload.png
        DESTINATION share/icons/hicolor/512x512/apps)
install(FILES packaging/org.speeddownload.SpeedDownload.desktop
        DESTINATION share/applications)
install(PROGRAMS "${CMAKE_CURRENT_SOURCE_DIR}/../../zig-out/bin/speed-download"
        DESTINATION bin OPTIONAL)
