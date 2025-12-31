cmake_minimum_required(VERSION 3.20)
project(eye_breaker LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
