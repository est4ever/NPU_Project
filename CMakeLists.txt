cmake_minimum_required(VERSION 3.18)
project(NPU_Project LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /MD")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
set(CMAKE_BUILD_TYPE Release)

# Force Release configuration only
set(CMAKE_CONFIGURATION_TYPES "Release" CACHE STRING "Supported build types" FORCE)

# IMPORTANT: use forward slashes
set(OpenVINO_DIR "C:/Users/ser13/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/ser13/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
message(STATUS "OpenVINO_DIR = ${OpenVINO_DIR}")

find_package(OpenVINO CONFIG REQUIRED)
find_package(OpenVINOGenAI CONFIG REQUIRED)

add_executable(npu_wrapper src/main.cpp)

add_custom_command(TARGET npu_wrapper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        $<TARGET_FILE:npu_wrapper>
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "C:/Users/ser13/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/bin/intel64/Release"
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        "C:/Windows/System32/msvcp140.dll"
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        "C:/Windows/System32/vcruntime140.dll"
        ${CMAKE_SOURCE_DIR}/dist/
    COMMENT "Copying OpenVINO runtime libraries to dist/"
)

target_link_libraries(npu_wrapper PRIVATE
    openvino::runtime
    openvino::genai
)