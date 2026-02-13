cmake_minimum_required(VERSION 3.18)
project(NPU_Project LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

# IMPORTANT: use forward slashes
set(OpenVINO_DIR "C:/Users/linsh/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/linsh/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
message(STATUS "OpenVINO_DIR = ${OpenVINO_DIR}")

find_package(OpenVINO CONFIG REQUIRED)
find_package(OpenVINOGenAI CONFIG REQUIRED)

add_executable(npu_wrapper src/main.cpp)

add_custom_command(TARGET npu_wrapper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
        $<TARGET_FILE:npu_wrapper>
        ${CMAKE_SOURCE_DIR}/dist/
)

target_link_libraries(npu_wrapper PRIVATE
    openvino::runtime
    openvino::genai
)