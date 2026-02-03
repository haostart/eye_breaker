cmake_minimum_required(VERSION 3.20)
project(eye_breaker LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(APPLE)
    add_executable(eye_breaker MACOSX_BUNDLE
        src/macos_main.mm
    )

    target_compile_options(eye_breaker PRIVATE
        "-fobjc-arc"
    )

    target_link_libraries(eye_breaker PRIVATE
        "-framework Cocoa"
        "-framework CoreGraphics"
        "-framework CoreText"
        "-framework ImageIO"
        "-framework QuartzCore"
        "-framework UniformTypeIdentifiers"
    )

    set_target_properties(eye_breaker PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist"
    )

    set(MAC_RESOURCES
        assets/bg.png
        assets/icon.icns
        assets/icon.ico
        assets/lang_en.txt
        assets/lang_zh.txt
    )

    foreach(resource IN LISTS MAC_RESOURCES)
        if(resource STREQUAL "assets/icon.icns")
            set_source_files_properties(${resource} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
        else()
            set_source_files_properties(${resource} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/assets")
        endif()
    endforeach()

    target_sources(eye_breaker PRIVATE ${MAC_RESOURCES})
else()
    add_executable(eye_breaker WIN32
        src/main.cpp
        app.rc
    )

    target_include_directories(eye_breaker PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
    )

    target_compile_definitions(eye_breaker PRIVATE
        UNICODE
        _UNICODE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
    )

    target_link_libraries(eye_breaker PRIVATE
        d2d1
        dwrite
        windowscodecs
        shell32
    )
endif()
