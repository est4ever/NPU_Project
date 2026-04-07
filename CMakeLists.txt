cmake_minimum_required(VERSION 3.18)
project(NPU_Project LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /MD")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
set(CMAKE_BUILD_TYPE Release)

# Force Release configuration only
set(CMAKE_CONFIGURATION_TYPES "Release" CACHE STRING "Supported build types" FORCE)

# Portable OpenVINO discovery order:
# 1) OPENVINO_GENAI_DIR env var (root folder containing setupvars.bat)
# 2) USERPROFILE/Downloads default paths
if(NOT DEFINED OpenVINO_DIR)
    if(DEFINED ENV{OPENVINO_GENAI_DIR})
        set(OpenVINO_DIR "$ENV{OPENVINO_GENAI_DIR}/runtime/cmake")
    elseif(EXISTS "$ENV{USERPROFILE}/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
        set(OpenVINO_DIR "$ENV{USERPROFILE}/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
    elseif(EXISTS "$ENV{USERPROFILE}/Downloads/openvino_genai_windows_2025.4.1.0_x86_64/runtime/cmake")
        set(OpenVINO_DIR "$ENV{USERPROFILE}/Downloads/openvino_genai_windows_2025.4.1.0_x86_64/runtime/cmake")
    endif()
endif()

if(NOT DEFINED OpenVINOGenAI_DIR)
    if(DEFINED ENV{OPENVINO_GENAI_DIR})
        set(OpenVINOGenAI_DIR "$ENV{OPENVINO_GENAI_DIR}/runtime/cmake")
    elseif(DEFINED OpenVINO_DIR)
        set(OpenVINOGenAI_DIR "${OpenVINO_DIR}")
    endif()
endif()

message(STATUS "OpenVINO_DIR = ${OpenVINO_DIR}")
message(STATUS "OpenVINOGenAI_DIR = ${OpenVINOGenAI_DIR}")

# Fetch header-only dependencies for REST API
include(FetchContent)

# cpp-httplib for HTTP server
FetchContent_Declare(
    httplib
    GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
    GIT_TAG v0.15.3
)
FetchContent_MakeAvailable(httplib)

# nlohmann/json for JSON parsing
FetchContent_Declare(
    json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
)
FetchContent_MakeAvailable(json)

find_package(OpenVINO CONFIG REQUIRED)
find_package(OpenVINOGenAI CONFIG REQUIRED)

add_executable(npu_wrapper
    src/main.cpp
    src/SpeculativeEngine.cpp
    src/RestAPIServer.cpp
    OpenVINO/Backend/OpenVINOBackend.cpp
    OpenVINO/Backend/BackendPool.cpp
    OpenVINO/Backend/KVCacheMonitor.cpp
    OpenVINO/Scheduler/OpenVINOScheduler.cpp
)

# Dist staging is handled by build.ps1 after a successful MSBuild,
# using PowerShell Copy-Item (more reliable than cmake -E copy on Windows).

target_link_libraries(npu_wrapper PRIVATE
    openvino::runtime
    openvino::genai
    httplib::httplib
    nlohmann_json::nlohmann_json
    psapi  # Windows Process Memory API
)