#include "RestAPIServer.h"
#include <httplib.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <sstream>
#include <chrono>
#include <iomanip>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <filesystem>
#include <optional>
#include <mutex>
#include <thread>
#include <vector>
#include <map>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <openvino/openvino.hpp>
#include "../OpenVINO/Backend/KVCacheMonitor.h"
#pragma comment(lib, "Psapi.lib")

using json = nlohmann::json;

namespace {
std::filesystem::path detect_project_root() {
    try {
        char exe_path[MAX_PATH]{};
        const DWORD len = GetModuleFileNameA(nullptr, exe_path, static_cast<DWORD>(sizeof(exe_path)));
        if (len > 0 && len < sizeof(exe_path)) {
            const std::filesystem::path exe_dir = std::filesystem::path(std::string(exe_path)).parent_path();
            std::vector<std::filesystem::path> candidates = {
                exe_dir,
                exe_dir.parent_path(),
                exe_dir.parent_path().parent_path()
            };
            for (const auto& candidate : candidates) {
                if (candidate.empty()) {
                    continue;
                }
                std::error_code ec;
                if (std::filesystem::exists(candidate / "run.ps1", ec) ||
                    std::filesystem::exists(candidate / "registry", ec)) {
                    return candidate;
                }
            }
        }
    } catch (...) {
        // Fall back to current working directory.
    }
    return std::filesystem::current_path();
}

const std::filesystem::path& project_root_path() {
    static const std::filesystem::path root = detect_project_root();
    return root;
}

const std::filesystem::path& registry_dir_path() {
    static const std::filesystem::path dir = project_root_path() / "registry";
    return dir;
}

const std::filesystem::path& models_registry_path() {
    static const std::filesystem::path path = registry_dir_path() / "models_registry.json";
    return path;
}

const std::filesystem::path& backends_registry_path() {
    static const std::filesystem::path path = registry_dir_path() / "backends_registry.json";
    return path;
}

const std::filesystem::path& performance_profile_path() {
    static const std::filesystem::path path = registry_dir_path() / "performance_profile.json";
    return path;
}

const std::filesystem::path& launch_state_path() {
    static const std::filesystem::path path = registry_dir_path() / "npu_launch_state.json";
    return path;
}

const std::filesystem::path& restart_script_path() {
    static const std::filesystem::path path = project_root_path() / "restart_backend.ps1";
    return path;
}

const std::filesystem::path& restart_stack_script_path() {
    static const std::filesystem::path path = project_root_path() / "restart_stack.ps1";
    return path;
}

const std::filesystem::path& last_error_log_path() {
    static const std::filesystem::path path = registry_dir_path() / "loomis_last_error.txt";
    return path;
}

json analyze_model_path_fs(const std::filesystem::path& resolved, const std::string& format_lower) {
    json r;
    std::error_code ec;
    if (!std::filesystem::exists(resolved, ec)) {
        r["exists"] = false;
        r["runnable_hint"] = "missing";
        return r;
    }
    r["exists"] = true;
    if (std::filesystem::is_regular_file(resolved, ec)) {
        r["kind"] = "file";
        std::string ext = resolved.extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        const bool is_gguf = (ext == ".gguf");
        r["gguf"] = is_gguf;
        r["runnable_hint"] = is_gguf ? "likely_gguf" : "unknown_file";
        return r;
    }
    if (!std::filesystem::is_directory(resolved, ec)) {
        r["runnable_hint"] = "unknown";
        return r;
    }
    r["kind"] = "directory";
    bool has_xml = false;
    int gguf_count = 0;
    bool has_st = false;
    for (const auto& e : std::filesystem::directory_iterator(resolved, ec)) {
        if (!e.is_regular_file()) {
            continue;
        }
        std::string ext = e.path().extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        if (ext == ".xml") {
            has_xml = true;
        }
        if (ext == ".gguf") {
            ++gguf_count;
        }
        if (ext == ".safetensors") {
            has_st = true;
        }
    }
    r["openvino_ir"] = has_xml;
    r["gguf_count"] = gguf_count;
    r["has_safetensors"] = has_st;
    std::string hint = "unknown";
    if (has_xml) {
        hint = "openvino_ir";
    } else if (gguf_count == 1) {
        hint = "single_gguf";
    } else if (gguf_count > 1) {
        hint = "multiple_gguf_ambiguous";
    } else if (has_st) {
        hint = "hf_safetensors_needs_export";
    }
    r["runnable_hint"] = hint;
    return r;
}

json try_http_get_localhost(int port, const char* path) {
    const std::string base = "http://127.0.0.1:" + std::to_string(port);
    httplib::Client cli(base.c_str());
    cli.set_connection_timeout(0, 400);
    cli.set_read_timeout(1, 0);
    auto res = cli.Get(path);
    json out;
    out["port"] = port;
    if (!res) {
        out["reachable"] = false;
        out["status"] = 0;
        return out;
    }
    out["reachable"] = res->status >= 200 && res->status < 500;
    out["status"] = res->status;
    return out;
}
}

void save_npu_launch_state(int argc, char** argv) {
    try {
        std::filesystem::create_directories(registry_dir_path());
        json argv_json = json::array();
        for (int i = 1; i < argc; ++i) {
            argv_json.push_back(argv[i] ? std::string(argv[i]) : std::string());
        }
        json doc = json::object();
        doc["argv"] = argv_json;
        doc["project_root"] = project_root_path().string();
        doc["backend_pid"] = static_cast<int>(GetCurrentProcessId());
        std::ofstream f(launch_state_path());
        f << doc.dump(2);
    } catch (...) {
    }
}

RestAPIServer::RestAPIServer(BackendPool* pool, int port)
    : RestAPIServer(pool, nullptr, port) {}

RestAPIServer::RestAPIServer(BackendPool* pool, RuntimeConfig* config, int port)
    : RestAPIServer(pool, config, nullptr, port) {}

namespace {
std::mutex g_metrics_file_mutex;
std::atomic<int> g_active_chat_requests{0};

std::optional<json> current_process_memory_json() {
    const auto to_mb = [](SIZE_T bytes) -> int64_t {
        return static_cast<int64_t>(bytes / (1024ull * 1024ull));
    };

    PROCESS_MEMORY_COUNTERS_EX pmc_ex{};
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc_ex), sizeof(pmc_ex))) {
        return json{
            {"pid", static_cast<int64_t>(GetCurrentProcessId())},
            {"working_set_mb", to_mb(pmc_ex.WorkingSetSize)},
            {"private_mb", to_mb(pmc_ex.PrivateUsage)},
            {"peak_working_set_mb", to_mb(pmc_ex.PeakWorkingSetSize)}
        };
    }

    PROCESS_MEMORY_COUNTERS pmc{};
    if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        return json{
            {"pid", static_cast<int64_t>(GetCurrentProcessId())},
            {"working_set_mb", to_mb(pmc.WorkingSetSize)},
            {"private_mb", to_mb(pmc.PagefileUsage)},
            {"peak_working_set_mb", to_mb(pmc.PeakWorkingSetSize)}
        };
    }

    return std::nullopt;
}

json probe_available_devices() {
    json devices = json::array();
    try {
        ov::Core core;
        for (const auto& id : core.get_available_devices()) {
            json item = { {"id", id} };
            try {
                item["name"] = core.get_property(id, ov::device::full_name);
            } catch (...) {
                item["name"] = "unknown";
            }
            devices.push_back(item);
        }
    } catch (...) {
        // Keep diagnostics best-effort to avoid masking original load failures.
    }
    return devices;
}

json build_device_load_hints(const std::string& device, const std::string& error_text, const json& available) {
    json hints = json::array();
    std::string upper_device = device;
    std::transform(upper_device.begin(), upper_device.end(), upper_device.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    std::string lower_error = error_text;
    std::transform(lower_error.begin(), lower_error.end(), lower_error.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    if (upper_device == "GPU") {
        hints.push_back("Verify Intel GPU drivers and OpenVINO GPU runtime are installed.");
        hints.push_back("Try CPU or NPU first: .\\npu_cli.ps1 -Command switch -Arguments \"CPU\"");
        hints.push_back("Attempt explicit preload: .\\npu_cli.ps1 -Command load -Arguments \"GPU\"");
    }
    if (upper_device == "NPU") {
        hints.push_back("Confirm Intel NPU runtime/driver package is installed and up to date.");
        hints.push_back("Fallback quickly with .\\npu_cli.ps1 -Command switch -Arguments \"CPU\".");
    }
    if (available.empty()) {
        hints.push_back("No accelerator devices were discovered by OpenVINO on this host.");
    }
    if (lower_error.find("unsupported") != std::string::npos ||
        lower_error.find("not found") != std::string::npos) {
        hints.push_back("The requested device plugin may be missing in the active OpenVINO runtime.");
    }
    return hints;
}

void set_json_response(httplib::Response& res, const json& body, int status = 200) {
    res.status = status;
    res.set_content(body.dump(), "application/json");
}

void set_error_response(
    httplib::Response& res,
    int status,
    const std::string& code,
    const std::string& message,
    const json& details = nullptr
) {
    json error = {
        {"error", {
            {"code", code},
            {"message", message}
        }}
    };

    if (!details.is_null()) {
        error["error"]["details"] = details;
    }

    set_json_response(res, error, status);
}

void ensure_registry_dir() {
    std::error_code ec;
    std::filesystem::create_directories(registry_dir_path(), ec);
}

json default_models_registry() {
    return {
        {"schema", 1},
        {"auto_select_best_model", false},
        {"selected_model", "openvino-local"},
        {"models", json::array({
            {
                {"id", "openvino-local"},
                {"path", "./models/Qwen2.5-0.5B-Instruct"},
                {"format", "openvino"},
                {"backend", "openvino"},
                {"status", "ready"}
            }
        })}
    };
}

json default_backends_registry() {
    return {
        {"schema", 1},
        {"selected_backend", "openvino"},
        {"backends", json::array({
            {
                {"id", "openvino"},
                {"type", "builtin"},
                {"entrypoint", "dist/npu_wrapper.exe"},
                {"formats", json::array({"openvino"})},
                {"status", "ready"}
            }
        })}
    };
}

std::string utf16le_to_utf8(const std::string& raw) {
    if (raw.size() < 2 || (raw.size() % 2) != 0) {
        return "";
    }
    std::wstring wide;
    wide.reserve(raw.size() / 2);
    for (size_t i = 0; i + 1 < raw.size(); i += 2) {
        const unsigned char lo = static_cast<unsigned char>(raw[i]);
        const unsigned char hi = static_cast<unsigned char>(raw[i + 1]);
        wide.push_back(static_cast<wchar_t>((hi << 8) | lo));
    }
    if (!wide.empty() && wide.front() == 0xFEFF) {
        wide.erase(wide.begin());
    }
    if (wide.empty()) {
        return "";
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return "";
    }
    std::string out(static_cast<size_t>(needed), '\0');
    const int written = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), needed, nullptr, nullptr);
    if (written <= 0) {
        return "";
    }
    return out;
}

json parse_registry_text(const std::string& raw) {
    if (raw.empty()) {
        throw std::runtime_error("empty_registry");
    }
    std::string text = raw;
    if (text.size() >= 3 &&
        static_cast<unsigned char>(text[0]) == 0xEF &&
        static_cast<unsigned char>(text[1]) == 0xBB &&
        static_cast<unsigned char>(text[2]) == 0xBF) {
        text.erase(0, 3);
    } else if (text.size() >= 2 &&
               static_cast<unsigned char>(text[0]) == 0xFF &&
               static_cast<unsigned char>(text[1]) == 0xFE) {
        const std::string utf8 = utf16le_to_utf8(text);
        if (!utf8.empty()) {
            text = utf8;
        }
    }
    return json::parse(text);
}

json load_registry(const std::string& path, const json& defaults) {
    ensure_registry_dir();
    std::ifstream in(path, std::ios::binary);
    if (!in.is_open()) {
        return defaults;
    }
    try {
        const std::string raw((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        return parse_registry_text(raw);
    } catch (...) {
        return defaults;
    }
}

void save_registry(const std::string& path, const json& data) {
    ensure_registry_dir();
    try {
        if (std::filesystem::exists(path)) {
            const std::string backup_path = path + ".bak";
            std::error_code copy_ec;
            std::filesystem::copy_file(
                path,
                backup_path,
                std::filesystem::copy_options::overwrite_existing,
                copy_ec
            );
        }
    } catch (...) {
        // Backup is best-effort; never block normal registry writes.
    }
    std::ofstream out(path, std::ios::trunc);
    out << data.dump(2);
}

json load_models_registry() {
    json reg = load_registry(models_registry_path().string(), default_models_registry());
    if (!reg.contains("models") || !reg["models"].is_array()) {
        reg["models"] = json::array();
    }
    if (!reg.contains("auto_select_best_model") || !reg["auto_select_best_model"].is_boolean()) {
        reg["auto_select_best_model"] = false;
    }
    if (!reg.contains("selected_model") || !reg["selected_model"].is_string()) {
        reg["selected_model"] = "openvino-local";
    }
    return reg;
}

std::filesystem::path resolve_registry_model_path(const std::string& model_path_raw) {
    auto trim_ws = [](const std::string& s) {
        const auto begin = std::find_if_not(s.begin(), s.end(), [](unsigned char ch) { return std::isspace(ch) != 0; });
        if (begin == s.end()) {
            return std::string();
        }
        const auto end = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char ch) { return std::isspace(ch) != 0; }).base();
        return std::string(begin, end);
    };
    std::string path_str = trim_ws(model_path_raw);
    if (path_str.empty()) {
        return {};
    }
    if ((path_str.front() == '"' && path_str.back() == '"') ||
        (path_str.front() == '\'' && path_str.back() == '\'')) {
        if (path_str.size() >= 2) {
            path_str = path_str.substr(1, path_str.size() - 2);
        }
    }
    std::filesystem::path p(path_str);
    if (p.is_relative()) {
        p = project_root_path() / p;
    }
    return p.lexically_normal();
}

json visible_models_registry(json reg) {
    if (!reg.contains("models") || !reg["models"].is_array()) {
        reg["models"] = json::array();
        reg["selected_model"] = "";
        return reg;
    }

    const std::string selected = reg.value("selected_model", "");
    json visible = json::array();
    for (const auto& item : reg["models"]) {
        if (!item.is_object()) {
            continue;
        }
        const std::string path_raw = item.value("path", "");
        const auto resolved = resolve_registry_model_path(path_raw);
        std::error_code ec;
        if (!resolved.empty() && std::filesystem::exists(resolved, ec) && !ec) {
            visible.push_back(item);
        }
    }

    reg["models"] = visible;
    bool selected_visible = false;
    for (const auto& item : visible) {
        if (item.is_object() && item.value("id", "") == selected) {
            selected_visible = true;
            break;
        }
    }
    if (!selected.empty() && selected_visible) {
        reg["selected_model"] = selected;
    } else if (!visible.empty()) {
        reg["selected_model"] = visible[0].value("id", "");
    } else {
        reg["selected_model"] = "";
    }
    return reg;
}

json load_backends_registry() {
    json reg = load_registry(backends_registry_path().string(), default_backends_registry());
    if (!reg.contains("backends") || !reg["backends"].is_array()) {
        reg["backends"] = json::array();
    }
    if (!reg.contains("selected_backend") || !reg["selected_backend"].is_string()) {
        reg["selected_backend"] = "openvino";
    }
    return reg;
}

bool has_registry_item(const json& arr, const std::string& id) {
    for (const auto& item : arr) {
        if (item.is_object() && item.value("id", "") == id) {
            return true;
        }
    }
    return false;
}

std::string trim_copy(const std::string& s) {
    const auto begin = std::find_if_not(s.begin(), s.end(), [](unsigned char ch) { return std::isspace(ch) != 0; });
    if (begin == s.end()) {
        return "";
    }
    const auto end = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char ch) { return std::isspace(ch) != 0; }).base();
    return std::string(begin, end);
}

std::string to_lower_copy(const std::string& s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return out;
}

std::string registry_model_format(const json& models, const std::string& id) {
    for (const auto& item : models) {
        if (!item.is_object()) {
            continue;
        }
        if (item.value("id", "") != id) {
            continue;
        }
        return to_lower_copy(trim_copy(item.value("format", "")));
    }
    return "";
}

// Human-facing hint when registry format will not load in npu_wrapper (OpenVINO GenAI / IR).
std::string npu_wrapper_format_warning(const std::string& format_lower) {
    if (format_lower == "gguf") {
        return "GGUF entries use OpenVINO GenAI direct GGUF loading when you point at a single .gguf or a folder with one .gguf "
               "(GenAI 2025.2+, preview; not all models/devices). IR (.xml) folders are still supported. If load fails, export IR or check toolkit version.";
    }
    if (format_lower == "pytorch" || format_lower == "pt" || format_lower == "safetensors" || format_lower == "hf") {
        return "This format is not loaded directly by npu_wrapper. Export to OpenVINO IR and point path at that folder to run inference.";
    }
    return {};
}

bool starts_with(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

std::string to_upper_copy(const std::string& s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return out;
}

bool parse_command(const std::string& raw, std::string& command, std::string& argument) {
    const std::string trimmed = trim_copy(raw);
    if (trimmed.empty()) {
        return false;
    }

    const std::string lower = to_lower_copy(trimmed);
    if (lower == "help" || lower == "/help") {
        command = "help";
        argument.clear();
        return true;
    }
    if (lower == "stats" || lower == "/stats") {
        command = "stats";
        argument.clear();
        return true;
    }
    if (lower == "devices" || lower == "/devices") {
        command = "devices";
        argument.clear();
        return true;
    }
    if (lower == "status" || lower == "/status" || lower == "info" || lower == "/info") {
        command = "status";
        argument.clear();
        return true;
    }
    if (lower == "health" || lower == "/health") {
        command = "health";
        argument.clear();
        return true;
    }
    if (lower == "model" || lower == "/model" || lower == "models" || lower == "/models") {
        command = "model";
        argument.clear();
        return true;
    }
    if (lower == "memory" || lower == "/memory") {
        command = "memory";
        argument.clear();
        return true;
    }
    if (starts_with(lower, "switch ") || starts_with(lower, "/switch ")) {
        command = "switch";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (starts_with(lower, "policy ") || starts_with(lower, "/policy ")) {
        command = "policy";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (starts_with(lower, "json ") || starts_with(lower, "/json ")) {
        command = "json";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "split-prefill ") || starts_with(lower, "/split-prefill ")) {
        command = "split-prefill";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "context-routing ") || starts_with(lower, "/context-routing ")) {
        command = "context-routing";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "optimize-memory ") || starts_with(lower, "/optimize-memory ")) {
        command = "optimize-memory";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "threshold ") || starts_with(lower, "/threshold ")) {
        command = "threshold";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (lower == "auto" || lower == "/auto") {
        command = "auto";
        argument.clear();
        return true;
    }
    if (lower == "benchmark" || lower == "/benchmark") {
        command = "benchmark";
        argument.clear();
        return true;
    }
    if (lower == "calibrate" || lower == "/calibrate") {
        command = "calibrate";
        argument.clear();
        return true;
    }
    if (lower == "metrics" || lower == "/metrics") {
        command = "metrics";
        argument = "last";
        return true;
    }
    if (starts_with(lower, "metrics ") || starts_with(lower, "/metrics ")) {
        command = "metrics";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "last" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }

    return false;
}

std::optional<json> read_latest_metrics_record() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    for (const auto& path : candidates) {
        std::ifstream in(path);
        if (!in.is_open()) {
            continue;
        }

        std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        content.erase(std::remove(content.begin(), content.end(), '\0'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\r'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\n'), content.end());

        // Strip UTF-8 BOM if present.
        if (content.size() >= 3 &&
            static_cast<unsigned char>(content[0]) == 0xEF &&
            static_cast<unsigned char>(content[1]) == 0xBB &&
            static_cast<unsigned char>(content[2]) == 0xBF) {
            content = content.substr(3);
        }

        std::optional<json> last_record;
        for (size_t i = 0; i < content.size(); ++i) {
            if (content[i] != '{') {
                continue;
            }

            bool in_string = false;
            bool escaped = false;
            int depth = 0;
            for (size_t j = i; j < content.size(); ++j) {
                const char ch = content[j];

                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }

                if (ch == '"') {
                    in_string = true;
                    continue;
                }
                if (ch == '{') {
                    ++depth;
                } else if (ch == '}') {
                    --depth;
                    if (depth == 0) {
                        const std::string candidate = content.substr(i, j - i + 1);
                        try {
                            last_record = json::parse(candidate);
                        } catch (...) {
                            // Keep scanning for a valid object.
                        }
                        break;
                    }
                }
            }
        }

        if (last_record.has_value()) {
            return last_record;
        }
    }

    return std::nullopt;
}

std::vector<json> read_all_metrics_records() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    for (const auto& path : candidates) {
        std::ifstream in(path);
        if (!in.is_open()) {
            continue;
        }

        std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        content.erase(std::remove(content.begin(), content.end(), '\0'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\r'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\n'), content.end());

        if (content.size() >= 3 &&
            static_cast<unsigned char>(content[0]) == 0xEF &&
            static_cast<unsigned char>(content[1]) == 0xBB &&
            static_cast<unsigned char>(content[2]) == 0xBF) {
            content = content.substr(3);
        }

        std::vector<json> records;
        for (size_t i = 0; i < content.size(); ++i) {
            if (content[i] != '{') {
                continue;
            }

            bool in_string = false;
            bool escaped = false;
            int depth = 0;
            for (size_t j = i; j < content.size(); ++j) {
                const char ch = content[j];
                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }

                if (ch == '"') {
                    in_string = true;
                    continue;
                }
                if (ch == '{') {
                    ++depth;
                } else if (ch == '}') {
                    --depth;
                    if (depth == 0) {
                        const std::string candidate = content.substr(i, j - i + 1);
                        try {
                            records.push_back(json::parse(candidate));
                        } catch (...) {
                            // Ignore malformed object and continue.
                        }
                        break;
                    }
                }
            }
        }

        if (!records.empty()) {
            return records;
        }
    }

    return {};
}

size_t clear_metrics_files() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    size_t removed = 0;
    for (const auto& path : candidates) {
        std::error_code ec;
        if (std::filesystem::exists(path, ec) && !ec) {
            if (std::filesystem::remove(path, ec) && !ec) {
                ++removed;
            }
        }
    }
    return removed;
}

void append_metrics_record(const json& record) {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    std::lock_guard<std::mutex> guard(g_metrics_file_mutex);
    for (const auto& path : candidates) {
        std::ofstream out(path, std::ios::app);
        if (!out.is_open()) {
            continue;
        }
        out << record.dump() << "\n";
        out.flush();
        return;
    }
}

std::string profile_for_policy(EnginePolicy p) {
    switch (p) {
        case EnginePolicy::PERFORMANCE: return "balanced-performance";
        case EnginePolicy::BATTERY_SAVER: return "latency-first";
        case EnginePolicy::BALANCED:
        default: return "default";
    }
}

void persist_performance_profile(const RuntimeConfig* config) {
    if (!config) return;
    json j = {
        {"policy", policy_to_string(config->get_policy())},
        {"performance_profile", config->get_performance_profile()},
        {"performance_reason", config->get_performance_reason()}
    };
    std::ofstream out(performance_profile_path());
    if (out.is_open()) {
        out << j.dump(2);
    }
}

void try_load_performance_profile(RuntimeConfig* config) {
    if (!config) return;
    std::ifstream in(performance_profile_path());
    if (!in.is_open()) return;
    try {
        json j = json::parse(in);
        const std::string policy = j.value("policy", "");
        if (!policy.empty()) {
            config->set_policy(string_to_policy(policy));
        }
        const std::string profile = j.value("performance_profile", profile_for_policy(config->get_policy()));
        const std::string reason = j.value("performance_reason", "persisted-profile");
        config->set_performance_profile(profile, reason);
    } catch (...) {
    }
}
}

RestAPIServer::RestAPIServer(BackendPool* pool, RuntimeConfig* config, KVCacheMonitor* kv_monitor, int port)
    : backend_pool_(pool), config_(config ? config : &default_config_), kv_monitor_(kv_monitor), port_(port), running_(false) {
    if (!config) {
        try_load_performance_profile(config_);
    }
    server_ = std::make_unique<httplib::Server>();
    
    // Set up CORS headers for all responses
    server_->set_default_headers({
        {"Access-Control-Allow-Origin", "*"},
        {"Access-Control-Allow-Methods", "GET, POST, OPTIONS"},
        {"Access-Control-Allow-Headers", "Content-Type, Authorization, x-npu-cli"}
    });
    
    // Register endpoints
    server_->Post("/v1/chat/completions", [this](const httplib::Request& req, httplib::Response& res) {
        handle_chat_completions(req, res);
    });
    
    server_->Get("/v1/models", [this](const httplib::Request& req, httplib::Response& res) {
        handle_list_models(req, res);
    });
    
    server_->Get("/health", [this](const httplib::Request& req, httplib::Response& res) {
        handle_health(req, res);
    });

    server_->Get("/v1/health", [this](const httplib::Request& req, httplib::Response& res) {
        handle_health(req, res);
    });
    
    // ===== CLI Endpoints - For terminal control commands =====
    server_->Get("/v1/cli/status", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_status(req, res);
    });
    
    server_->Post("/v1/cli/device/switch", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_device_switch(req, res);
    });

    server_->Post("/v1/cli/device/load", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_device_load(req, res);
    });
    
    server_->Post("/v1/cli/policy", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_policy(req, res);
    });
    
    server_->Post("/v1/cli/feature/(.*)", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_feature_toggle(req, res);
    });
    
    server_->Post("/v1/cli/threshold", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_threshold(req, res);
    });
    
    server_->Get("/v1/cli/metrics", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_metrics(req, res);
    });

    server_->Get("/v1/cli/events", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_events(req, res);
    });

    server_->Get("/v1/cli/memory", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_memory(req, res);
    });

    server_->Get("/v1/cli/model/list", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_list(req, res);
    });

    server_->Post("/v1/cli/model/import", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_import(req, res);
    });

    server_->Post("/v1/cli/model/select", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_select(req, res);
    });

    server_->Post("/v1/cli/model/rename", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_rename(req, res);
    });

    server_->Post("/v1/cli/model/auto-select", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_auto_select(req, res);
    });

    server_->Get("/v1/cli/backend/list", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_list(req, res);
    });

    server_->Post("/v1/cli/backend/add", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_add(req, res);
    });

    server_->Post("/v1/cli/backend/select", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_select(req, res);
    });

    server_->Post("/v1/cli/backend/restart", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_restart(req, res);
    });

    server_->Get("/v1/cli/readiness", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_readiness(req, res);
    });

    server_->Post("/v1/cli/model/validate", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_validate(req, res);
    });

    server_->Get("/v1/cli/backend/probe", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_probe(req, res);
    });

    server_->Post("/v1/cli/stack/restart", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_stack_restart(req, res);
    });

    server_->Get("/v1/cli/metrics/recommendation", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_metrics_recommendation(req, res);
    });

    server_->Get("/v1/cli/models/discover", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_models_discover(req, res);
    });

    server_->Post("/v1/cli/diagnostics/export", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_diagnostics_export(req, res);
    });
    
    server_->Options(".*", [](const httplib::Request&, httplib::Response& res) {
        res.status = 204; // No Content
    });
}

RestAPIServer::~RestAPIServer() {
    stop();
}

void RestAPIServer::start() {
    running_ = true;
    std::cout << "[RestAPI] Starting server on http://localhost:" << port_ << "\n";
    std::cout << "[RestAPI] Chat Endpoint:\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/chat/completions (pure chat only)\n";
    std::cout << "[RestAPI] Information Endpoints:\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/models\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/health\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/health\n";
    std::cout << "[RestAPI] CLI Control Endpoints (use npu_cli.ps1 tool):\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/status\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/device/switch\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/policy\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/feature/{feature}\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/threshold\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/metrics\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/model/list\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/model/import\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/model/select\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/model/rename\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/backend/list\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/backend/add\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/backend/select\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/backend/restart\n";
    std::cout.flush();
    
    std::cout << "[RestAPI] Attempting to bind to 0.0.0.0:" << port_ << "...\n";
    std::cout.flush();
    
    try {
        // First bind to the port (non-blocking)
        if (!server_->bind_to_port("0.0.0.0", port_)) {
            std::cerr << "[RestAPI] FAILED - Could not bind to port " << port_ << " (may be in use?)\n";
            std::cerr.flush();
            running_ = false;
            return;
        }
        
        std::cout << "[RestAPI] Successfully bound to port " << port_ << "\n";
        std::cout << "[RestAPI] Server is now READY and listening for requests\n";
        std::cout.flush();
        
        // Now start the blocking event loop
        if (!server_->listen_after_bind()) {
            std::cerr << "[RestAPI] Error in listen event loop\n";
            std::cerr.flush();
            running_ = false;
            return;
        }
    } catch (const std::exception& e) {
        std::cerr << "[RestAPI] EXCEPTION: " << e.what() << "\n";
        std::cerr.flush();
        running_ = false;
        return;
    } catch (...) {
        std::cerr << "[RestAPI] UNKNOWN EXCEPTION\n";
        std::cerr.flush();
        running_ = false;
        return;
    }
}

void RestAPIServer::stop() {
    if (running_) {
        std::cout << "[RestAPI] Stopping server...\n";
        server_->stop();
        running_ = false;
    }
}

bool RestAPIServer::is_running() const {
    return running_;
}

void RestAPIServer::handle_chat_completions(const httplib::Request& req, httplib::Response& res) {
    try {
        const std::string cli_header = req.get_header_value("x-npu-cli");
        if (to_lower_copy(cli_header) != "true") {
            set_error_response(
                res,
                403,
                "terminal_chat_only",
                "Chat is terminal-only. Use .\\npu_cli.ps1 -Command chat",
                json{{"required_header", "x-npu-cli: true"}}
            );
            return;
        }

        auto started = std::chrono::high_resolution_clock::now();
        struct ChatActiveGuard {
            ChatActiveGuard() { g_active_chat_requests.fetch_add(1, std::memory_order_relaxed); }
            ~ChatActiveGuard() { g_active_chat_requests.fetch_sub(1, std::memory_order_relaxed); }
        } chat_guard;

        // Parse incoming JSON request
        json request_body = json::parse(req.body);
        
        // Extract parameters
        std::string model = request_body.value("model", "openvino");
        bool stream = request_body.value("stream", false);
        float temperature = request_body.value("temperature", 0.7f);
        int max_tokens = request_body.value("max_tokens", 128);
        if (max_tokens <= 0) {
            max_tokens = 128;
        }
        
        // Build prompt from messages
        std::stringstream prompt_builder;
        std::string last_user_message;
        if (request_body.contains("messages") && request_body["messages"].is_array()) {
            for (const auto& message : request_body["messages"]) {
                std::string role = message.value("role", "user");
                std::string content;

                // OpenWebUI may send message.content as either a plain string or an array of parts.
                if (message.contains("content")) {
                    const auto& raw_content = message["content"];
                    if (raw_content.is_string()) {
                        content = raw_content.get<std::string>();
                    } else if (raw_content.is_array()) {
                        for (const auto& part : raw_content) {
                            if (part.is_string()) {
                                content += part.get<std::string>();
                            } else if (part.is_object()) {
                                if (part.value("type", "") == "text" && part.contains("text") && part["text"].is_string()) {
                                    content += part["text"].get<std::string>();
                                }
                            }
                        }
                    }
                }
                
                if (role == "system") {
                    prompt_builder << "System: " << content << "\n";
                } else if (role == "user") {
                    last_user_message = content;
                    prompt_builder << "User: " << content << "\n";
                } else if (role == "assistant") {
                    prompt_builder << "Assistant: " << content << "\n";
                }
            }
            prompt_builder << "Assistant: ";
        } else {
            // Fallback to "prompt" field if no messages
            last_user_message = request_body.value("prompt", "");
            prompt_builder << last_user_message;
        }
        
        std::string prompt = prompt_builder.str();

        auto* backend = backend_pool_->get_active_backend();
        if (!backend) {
            throw std::runtime_error("No active backend is available");
        }

        std::string command_name;
        std::string command_arg;
        std::string response_text;
        size_t completion_tokens = 0;
        bool generated_output = false;

        // Keep chat pure: if a user types a control command in chat, guide them to terminal CLI.
        if (parse_command(last_user_message, command_name, command_arg)) {
            response_text =
                "Control commands are now terminal-only.\n"
                "Use: .\\npu_cli.ps1 -Command help\n\n"
                "Examples:\n"
                "- .\\npu_cli.ps1 -Command status\n"
                "- .\\npu_cli.ps1 -Command switch -Arguments \"GPU\"\n"
                "- .\\npu_cli.ps1 -Command policy -Arguments \"PERFORMANCE\"\n"
                "- .\\npu_cli.ps1 -Command metrics -Arguments \"summary\"";
            completion_tokens = 0;
        } else {
            // Normal chat generation path.
            auto output = backend->generate_output(
                prompt, max_tokens, temperature, false
            );
            response_text = output.text;
            completion_tokens = output.token_ids.size();
            generated_output = true;
        }

        if (generated_output) {
            auto ended = std::chrono::high_resolution_clock::now();
            double total_ms = std::chrono::duration<double, std::milli>(ended - started).count();
            const BackendMetrics metrics = backend_pool_->get_active_metrics();

            json metrics_record = {
                {"timestamp", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"mode", "server"},
                {"device", backend_pool_->get_active_device()},
                {"policy", policy_to_string(config_->get_policy())},
                {"json_mode", config_->get_json_mode()},
                {"split_prefill", config_->get_split_prefill()},
                {"context_routing", config_->get_context_routing()},
                {"optimize_memory", config_->get_enable_kv_paging()},
                {"ttft_ms", metrics.ttft_ms},
                {"tpot_ms", metrics.tpot_ms},
                {"throughput_tok_s", metrics.throughput},
                {"total_ms", total_ms},
                {"completion_tokens", completion_tokens}
            };

            append_metrics_record(metrics_record);
        }
        
        if (stream) {

            const auto created = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
            const std::string chunk_id = "chatcmpl-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count());

            json role_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", {{"role", "assistant"}}},
                        {"finish_reason", nullptr}
                    }
                })}
            };

            json content_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", {{"content", response_text}}},
                        {"finish_reason", nullptr}
                    }
                })}
            };

            json final_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", json::object()},
                        {"finish_reason", "stop"}
                    }
                })}
            };
            std::string sse_data;
            sse_data += "data: " + role_chunk.dump() + "\n\n";
            sse_data += "data: " + content_chunk.dump() + "\n\n";
            sse_data += "data: " + final_chunk.dump() + "\n\n";
            sse_data += "data: [DONE]\n\n";

            res.set_content(sse_data, "text/event-stream");
            
        } else {
            // Non-streaming response
            // Format response in OpenAI format
            json response = {
                {"id", "chatcmpl-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count())},
                {"object", "chat.completion"},
                {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"message", {
                            {"role", "assistant"},
                            {"content", response_text}
                        }},
                        {"finish_reason", "stop"}
                    }
                })},
                {"usage", {
                    {"prompt_tokens", 0},  // Would need tokenizer access to compute
                    {"completion_tokens", completion_tokens},
                    {"total_tokens", completion_tokens}
                }}
            };
            
            res.set_content(response.dump(), "application/json");
        }
        
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "internal_error",
            "Failed to generate chat completion",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_events(const httplib::Request& req, httplib::Response& res) {
    (void)req;

    res.set_header("Cache-Control", "no-cache");
    res.set_header("Connection", "keep-alive");
    res.set_header("X-Accel-Buffering", "no");

    res.set_chunked_content_provider(
        "text/event-stream",
        [this](size_t, httplib::DataSink& sink) {
            if (!sink.is_writable()) {
                return false;
            }

            json event = {
                {"ts", std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count()},
                {"active_device", backend_pool_->get_active_device()},
                {"policy", policy_to_string(config_->get_policy())},
                {"loaded_devices", backend_pool_->get_loaded_devices()},
                {"thinking", g_active_chat_requests.load(std::memory_order_relaxed) > 0}
            };

            const BackendMetrics metrics = backend_pool_->get_active_metrics();
            event["ttft_ms"] = metrics.ttft_ms;
            event["tpot_ms"] = metrics.tpot_ms;
            event["throughput"] = metrics.throughput;

            const std::string frame = std::string("event: heartbeat\n") + "data: " + event.dump() + "\n\n";
            sink.write(frame.data(), frame.size());
            std::this_thread::sleep_for(std::chrono::milliseconds(900));
            return true;
        }
    );
}

void RestAPIServer::handle_list_models(const httplib::Request& req, httplib::Response& res) {
    json response = {
        {"object", "list"},
        {"data", json::array({
            {
                {"id", "openvino-local"},
                {"object", "model"},
                {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"owned_by", "local"},
                {"permission", json::array()},
                {"root", "openvino-local"},
                {"parent", nullptr}
            }
        })}
    };
    
    set_json_response(res, response);
}

void RestAPIServer::handle_health(const httplib::Request& req, httplib::Response& res) {
    json response = {
        {"status", "healthy"},
        {"backend", backend_pool_->get_active_device()}
    };
    
    set_json_response(res, response);
}

// ===== CLI Endpoint Implementations =====

void RestAPIServer::handle_cli_status(const httplib::Request& req, httplib::Response& res) {
    try {
        auto devices = backend_pool_->get_loaded_devices();
        BackendMetrics metrics = backend_pool_->get_active_metrics();
        
        json response = {
            {"policy", policy_to_string(config_->get_policy())},
            {"performance_profile", config_->get_performance_profile()},
            {"performance_reason", config_->get_performance_reason()},
            {"active_device", backend_pool_->get_active_device()},
            {"devices", devices},
            {"available_devices", probe_available_devices()},
            {"json_output", config_->get_json_mode() ? "ON" : "OFF"},
            {"split_prefill", config_->get_split_prefill() ? "ON" : "OFF"},
            {"context_routing", config_->get_context_routing() ? "ON" : "OFF"},
            {"optimize_memory", config_->get_enable_kv_paging() ? "ON" : "OFF"},
            {"ttft_ms", metrics.ttft_ms},
            {"tpot_ms", metrics.tpot_ms},
            {"throughput", metrics.throughput}
        };

        const json models_reg = visible_models_registry(load_models_registry());
        const json backends_reg = load_backends_registry();
        response["selected_model"] = models_reg.value("selected_model", "openvino-local");
        response["auto_select_best_model"] = models_reg.value("auto_select_best_model", false);
        response["selected_backend"] = backends_reg.value("selected_backend", "openvino");
        
        if (config_->get_split_prefill()) {
            response["prefill_device"] = config_->prefill_device;
            response["decode_device"] = config_->decode_device;
            response["threshold"] = config_->get_prefill_threshold_high();
        }
        
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "status_fetch_failed",
            "Failed to fetch CLI status",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_device_switch(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        std::string device = request_body.value("device", "");
        
        if (device.empty()) {
            set_error_response(res, 400, "missing_device", "device parameter required");
            return;
        }
        
        backend_pool_->set_active_device(device);
        std::string actual_device = backend_pool_->get_active_device();

        if (actual_device != device) {
            set_error_response(res, 422, "device_not_loaded",
                "Device " + device + " is not loaded in the current runtime");
            return;
        }

        json response = {
            {"new_active_device", actual_device},
            {"success", true}
        };

        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "device_switch_failed",
            "Failed to switch device",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_device_load(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        std::string device = request_body.value("device", "");

        if (device.empty()) {
            set_error_response(res, 400, "missing_device", "device parameter required");
            return;
        }

        // Normalise to upper-case to match OpenVINO conventions.
        std::transform(device.begin(), device.end(), device.begin(), ::toupper);

        std::string load_error;
        bool ok = backend_pool_->load_device(device, load_error);
        if (!ok) {
            const json available = probe_available_devices();
            const json details = {
                {"requested_device", device},
                {"loaded_devices", backend_pool_->get_loaded_devices()},
                {"available_devices", available},
                {"hints", build_device_load_hints(device, load_error, available)},
                {"raw_error", load_error}
            };
            set_error_response(res, 422, "device_load_failed",
                "Failed to load model on device " + device + ": " + load_error,
                details);
            return;
        }

        auto loaded = backend_pool_->get_loaded_devices();
        json response = {
            {"success", true},
            {"loaded_device", device},
            {"all_loaded_devices", loaded}
        };
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "device_load_error",
            "Exception while loading device",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_policy(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        std::string policy_str = request_body.value("policy", "");
        
        if (policy_str.empty()) {
            set_error_response(res, 400, "missing_policy", "policy parameter required");
            return;
        }
        
        EnginePolicy new_policy = string_to_policy(policy_str);
        config_->set_policy(new_policy);
        config_->set_performance_profile(profile_for_policy(new_policy), "api-policy-update");
        persist_performance_profile(config_);
        
        json response = {
            {"new_policy", policy_to_string(new_policy)},
            {"performance_profile", config_->get_performance_profile()},
            {"success", true}
        };
        
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "policy_update_failed",
            "Failed to update scheduling policy",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_feature_toggle(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        bool enabled = request_body.value("enabled", false);
        
        // Extract feature name from path
        std::string path = req.path;
        size_t last_slash = path.find_last_of('/');
        std::string feature = (last_slash != std::string::npos) ? path.substr(last_slash + 1) : "";
        
        if (feature.empty()) {
            set_error_response(res, 400, "missing_feature", "feature not specified in path");
            return;
        }
        
        json response = {{"feature", feature}};
        
        if (feature == "json") {
            config_->set_json_mode(enabled);
            response["status"] = enabled ? "enabled" : "disabled";
            response["success"] = true;
        } else if (feature == "split-prefill") {
            if (enabled && backend_pool_->get_loaded_devices().size() < 2) {
                set_error_response(
                    res,
                    409,
                    "insufficient_devices",
                    "At least 2 devices are required for split-prefill"
                );
                return;
            } else {
                config_->set_split_prefill(enabled);
                response["status"] = enabled ? "enabled" : "disabled";
                response["success"] = true;
            }
        } else if (feature == "context-routing") {
            config_->set_context_routing(enabled);
            response["status"] = enabled ? "enabled" : "disabled";
            response["success"] = true;
        } else if (feature == "optimize-memory") {
            config_->set_enable_kv_paging(enabled);
            if (kv_monitor_) {
                kv_monitor_->set_disk_paging_enabled(enabled, "./kv_cache_paging");
            }
            response["status"] = enabled ? "enabled" : "disabled";
            response["success"] = true;
            response["note"] = "Runtime flag updated. Full KV-cache optimization path is guaranteed when the stack is started with --optimize-memory.";
        } else {
            set_error_response(res, 400, "unknown_feature", "Unknown feature: " + feature);
            return;
        }
        
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "feature_toggle_failed",
            "Failed to update feature toggle",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_threshold(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        int threshold = request_body.value("threshold", 0);
        
        if (threshold <= 0) {
            set_error_response(res, 400, "invalid_threshold", "threshold must be positive");
            return;
        }
        
        config_->set_prefill_threshold_high(threshold);
        config_->set_prefill_threshold_low(std::max(1, static_cast<int>(threshold * 0.8)));
        
        json response = {
            {"new_threshold", threshold},
            {"low_threshold", config_->get_prefill_threshold_low()},
            {"success", true}
        };
        
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "threshold_update_failed",
            "Failed to update threshold",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_metrics(const httplib::Request& req, httplib::Response& res) {
    try {
        std::string mode = "last";
        if (req.has_param("mode")) {
            mode = req.get_param_value("mode");
        }
        
        json response;
        
        if (mode == "last") {
            const auto record = read_latest_metrics_record();
            if (!record.has_value()) {
                BackendMetrics live = backend_pool_->get_active_metrics();
                response = {
                    {"mode", "live_fallback"},
                    {"device", backend_pool_->get_active_device()},
                    {"policy", policy_to_string(config_->get_policy())},
                    {"json_mode", config_->get_json_mode()},
                    {"ttft_ms", live.ttft_ms},
                    {"tpot_ms", live.tpot_ms},
                    {"throughput_tok_s", live.throughput},
                    {"note", "No persisted metrics record found yet; showing current backend metrics."}
                };
            } else {
                response = record.value();
            }
        } else if (mode == "summary") {
            const auto records = read_all_metrics_records();
            if (records.empty()) {
                set_error_response(res, 404, "metrics_not_found", "No metrics records found");
                return;
            } else {
                double ttft_sum = 0.0, tpot_sum = 0.0, throughput_sum = 0.0;
                int ttft_count = 0, tpot_count = 0, throughput_count = 0;
                
                for (const auto& r : records) {
                    if (r.contains("ttft_ms") && r["ttft_ms"].is_number()) {
                        ttft_sum += r["ttft_ms"].get<double>();
                        ++ttft_count;
                    }
                    if (r.contains("tpot_ms") && r["tpot_ms"].is_number()) {
                        tpot_sum += r["tpot_ms"].get<double>();
                        ++tpot_count;
                    }
                    if (r.contains("throughput_tok_s") && r["throughput_tok_s"].is_number()) {
                        throughput_sum += r["throughput_tok_s"].get<double>();
                        ++throughput_count;
                    }
                }
                
                response = {
                    {"record_count", records.size()},
                    {"avg_ttft_ms", ttft_count > 0 ? ttft_sum / ttft_count : 0.0},
                    {"avg_tpot_ms", tpot_count > 0 ? tpot_sum / tpot_count : 0.0},
                    {"avg_throughput", throughput_count > 0 ? throughput_sum / throughput_count : 0.0}
                };
            }
        } else if (mode == "clear") {
            const size_t removed = clear_metrics_files();
            response = {
                {"cleared", removed > 0},
                {"files_removed", removed}
            };
        } else {
            set_error_response(
                res,
                400,
                "invalid_mode",
                "Invalid mode. Use: last, summary, or clear"
            );
            return;
        }
        
        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "metrics_query_failed",
            "Failed to query metrics",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_memory(const httplib::Request& req, httplib::Response& res) {
    try {
        if (!kv_monitor_) {
            set_error_response(
                res,
                503,
                "memory_monitor_unavailable",
                "KVCacheMonitor is not available in this runtime"
            );
            return;
        }

        const auto stats = kv_monitor_->get_memory_stats();
        json response = {
            {"optimize_memory", config_->get_enable_kv_paging() ? "ON" : "OFF"},
            {"disk_paging_enabled", kv_monitor_->is_disk_paging_enabled()},
            {"paging_directory", kv_monitor_->get_paging_directory()},
            {"ram", {
                {"total_mb", static_cast<int64_t>(stats.total_ram_mb)},
                {"used_mb", static_cast<int64_t>(stats.used_ram_mb)},
                {"available_mb", static_cast<int64_t>(stats.available_ram_mb)},
                {"usage_percent", static_cast<double>(stats.usage_percent * 100.0f)}
            }},
            {"vram", {
                {"total_mb", static_cast<int64_t>(stats.total_vram_mb)},
                {"used_mb", static_cast<int64_t>(stats.used_vram_mb)},
                {"available_mb", static_cast<int64_t>(stats.available_vram_mb)},
                {"usage_percent", static_cast<double>(stats.vram_usage_percent * 100.0f)}
            }}
        };

        if (const auto proc = current_process_memory_json(); proc.has_value()) {
            response["process"] = proc.value();
        }

        if (config_->get_enable_kv_paging()) {
            response["evidence"] = "INT8 KV-cache optimization is enabled; compare ram.used_mb / usage_percent before and after long prompts.";
        } else {
            response["evidence"] = "Optimization is OFF; enable optimize-memory to activate INT8 KV-cache path.";
        }

        set_json_response(res, response);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "memory_query_failed",
            "Failed to query memory status",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_model_list(const httplib::Request& req, httplib::Response& res) {
    try {
        json models_reg = visible_models_registry(load_models_registry());
        set_json_response(res, models_reg);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "model_list_failed",
            "Failed to load models registry",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_model_import(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = trim_copy(body.value("id", ""));
        const std::string path = trim_copy(body.value("path", ""));
        const std::string format = to_lower_copy(trim_copy(body.value("format", "openvino")));
        const std::string backend = to_lower_copy(trim_copy(body.value("backend", "openvino")));
        const std::string status = trim_copy(body.value("status", "ready"));

        if (id.empty() || path.empty()) {
            set_error_response(
                res,
                400,
                "missing_required_fields",
                "id and path are required",
                json{{"required", json::array({"id", "path"})}}
            );
            return;
        }

        json models_reg = load_models_registry();
        bool updated = false;
        for (auto& item : models_reg["models"]) {
            if (item.value("id", "") == id) {
                item["path"] = path;
                item["format"] = format;
                item["backend"] = backend;
                item["status"] = status;
                updated = true;
                break;
            }
        }

        if (!updated) {
            models_reg["models"].push_back({
                {"id", id},
                {"path", path},
                {"format", format},
                {"backend", backend},
                {"status", status}
            });
        }

        if (!models_reg.contains("selected_model") || models_reg["selected_model"].get<std::string>().empty()) {
            models_reg["selected_model"] = id;
        }

        save_registry(models_registry_path().string(), models_reg);

        json body_out = {
            {"success", true},
            {"updated", updated},
            {"id", id},
            {"format", format},
            {"note", "Model registered. Restart stack to load a newly selected model."}
        };
        const std::string fmt_warn = npu_wrapper_format_warning(format);
        if (!fmt_warn.empty()) {
            body_out["warning"] = fmt_warn;
        }

        set_json_response(res, body_out);
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "model_import_failed",
            "Failed to import model",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_model_select(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = trim_copy(body.value("id", ""));
        if (id.empty()) {
            set_error_response(res, 400, "missing_id", "id is required");
            return;
        }

        json models_reg = load_models_registry();
        if (!has_registry_item(models_reg["models"], id)) {
            set_error_response(res, 404, "model_not_found", "Model not found: " + id);
            return;
        }

        models_reg["selected_model"] = id;
        save_registry(models_registry_path().string(), models_reg);

        const std::string fmt = registry_model_format(models_reg["models"], id);
        json body_out = {
            {"success", true},
            {"selected_model", id},
            {"format", fmt},
            {"note", "Selection saved. Restart stack to apply model change."}
        };
        const std::string fmt_warn = npu_wrapper_format_warning(fmt);
        if (!fmt_warn.empty()) {
            body_out["warning"] = fmt_warn;
        }

        set_json_response(res, body_out);
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "model_select_failed",
            "Failed to select model",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_model_rename(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string from_id = trim_copy(body.value("from_id", ""));
        const std::string to_id = trim_copy(body.value("to_id", ""));

        if (from_id.empty() || to_id.empty()) {
            set_error_response(
                res,
                400,
                "missing_required_fields",
                "from_id and to_id are required",
                json{{"required", json::array({"from_id", "to_id"})}}
            );
            return;
        }

        if (from_id == to_id) {
            set_json_response(res, json({
                {"success", true},
                {"from_id", from_id},
                {"to_id", to_id},
                {"unchanged", true},
                {"note", "New id matches current id."}
            }));
            return;
        }

        json models_reg = load_models_registry();
        if (!has_registry_item(models_reg["models"], from_id)) {
            set_error_response(res, 404, "model_not_found", "Model not found: " + from_id);
            return;
        }
        if (has_registry_item(models_reg["models"], to_id)) {
            set_error_response(
                res,
                409,
                "id_already_exists",
                "A model with this id already exists: " + to_id
            );
            return;
        }

        for (auto& item : models_reg["models"]) {
            if (item.value("id", "") == from_id) {
                item["id"] = to_id;
                break;
            }
        }

        if (models_reg.contains("selected_model") && models_reg["selected_model"].get<std::string>() == from_id) {
            models_reg["selected_model"] = to_id;
        }

        save_registry(models_registry_path().string(), models_reg);
        set_json_response(res, json({
            {"success", true},
            {"from_id", from_id},
            {"to_id", to_id},
            {"selected_model", models_reg.value("selected_model", "")},
            {"note", "Model id updated. Restart stack if this model is loaded."}
        }));
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "model_rename_failed",
            "Failed to rename model",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_model_auto_select(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        if (!body.contains("enabled")) {
            set_error_response(
                res,
                400,
                "missing_required_fields",
                "enabled is required",
                json{{"required", json::array({"enabled"})}}
            );
            return;
        }
        const bool enabled = body.value("enabled", false);
        json models_reg = load_models_registry();
        models_reg["auto_select_best_model"] = enabled;
        save_registry(models_registry_path().string(), models_reg);

        set_json_response(res, json({
            {"success", true},
            {"auto_select_best_model", enabled},
            {"note", "Saved. Applies on next .\\start_app.ps1 launch."}
        }));
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "model_auto_select_update_failed",
            "Failed to update auto-select model setting",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_backend_list(const httplib::Request& req, httplib::Response& res) {
    try {
        json backends_reg = load_backends_registry();
        set_json_response(res, backends_reg);
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "backend_list_failed",
            "Failed to load backends registry",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_backend_add(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = to_lower_copy(trim_copy(body.value("id", "")));
        const std::string type = trim_copy(body.value("type", "external"));
        const std::string entrypoint = trim_copy(body.value("entrypoint", ""));
        json formats = body.contains("formats") && body["formats"].is_array()
            ? body["formats"]
            : json::array({"openvino"});

        if (id.empty() || entrypoint.empty()) {
            set_error_response(
                res,
                400,
                "missing_required_fields",
                "id and entrypoint are required",
                json{{"required", json::array({"id", "entrypoint"})}}
            );
            return;
        }

        json backends_reg = load_backends_registry();
        bool updated = false;
        for (auto& item : backends_reg["backends"]) {
            if (item.value("id", "") == id) {
                item["type"] = type;
                item["entrypoint"] = entrypoint;
                item["formats"] = formats;
                item["status"] = "ready";
                updated = true;
                break;
            }
        }
        if (!updated) {
            backends_reg["backends"].push_back({
                {"id", id},
                {"type", type},
                {"entrypoint", entrypoint},
                {"formats", formats},
                {"status", "ready"}
            });
        }

        save_registry(backends_registry_path().string(), backends_reg);
        set_json_response(res, json({
            {"success", true},
            {"updated", updated},
            {"id", id}
        }));
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "backend_add_failed",
            "Failed to add backend",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_backend_select(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = to_lower_copy(trim_copy(body.value("id", "")));
        if (id.empty()) {
            set_error_response(res, 400, "missing_id", "id is required");
            return;
        }

        json backends_reg = load_backends_registry();
        if (!has_registry_item(backends_reg["backends"], id)) {
            set_error_response(res, 404, "backend_not_found", "Backend not found: " + id);
            return;
        }

        backends_reg["selected_backend"] = id;
        save_registry(backends_registry_path().string(), backends_reg);
        set_json_response(res, json({
            {"success", true},
            {"selected_backend", id},
            {"note", "Selection saved. The app shell will call /v1/cli/backend/restart after this; or invoke that endpoint yourself to relaunch run.ps1 with the new entrypoint."}
        }));
    } catch (const json::exception& e) {
        set_error_response(
            res,
            400,
            "invalid_json",
            "Invalid JSON in request body",
            json{{"exception", e.what()}}
        );
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "backend_select_failed",
            "Failed to select backend",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_backend_restart(const httplib::Request&, httplib::Response& res) {
    try {
        if (!std::filesystem::exists(launch_state_path())) {
            set_error_response(
                res,
                400,
                "launch_state_missing",
                "registry/npu_launch_state.json not found. Start the backend from run.ps1 / start_app.ps1 once, then try again."
            );
            return;
        }
        if (!std::filesystem::exists(restart_script_path())) {
            set_error_response(
                res,
                500,
                "restart_script_missing",
                "restart_backend.ps1 not found in project root."
            );
            return;
        }
        const std::string root = project_root_path().string();
        const std::string script = restart_script_path().string();

        set_json_response(res, json({
            {"success", true},
            {"note", "Backend restart scheduled. This process will exit; run.ps1 will start again with the selected backend entrypoint."}
        }));

        std::thread([root, script]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(900));
            std::string cmd =
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            STARTUPINFOA si{};
            si.cb = sizeof(si);
            PROCESS_INFORMATION pi{};
            std::vector<char> cmdline(cmd.begin(), cmd.end());
            cmdline.push_back('\0');
            CreateProcessA(
                nullptr,
                cmdline.data(),
                nullptr,
                nullptr,
                FALSE,
                0,
                nullptr,
                root.c_str(),
                &si,
                &pi);
            if (pi.hThread) {
                CloseHandle(pi.hThread);
            }
            if (pi.hProcess) {
                CloseHandle(pi.hProcess);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(400));
            ExitProcess(0);
        }).detach();
    } catch (const std::exception& e) {
        set_error_response(
            res,
            500,
            "backend_restart_failed",
            "Failed to schedule restart",
            json{{"exception", e.what()}}
        );
    }
}

void RestAPIServer::handle_cli_readiness(const httplib::Request&, httplib::Response& res) {
    try {
        json out;
        out["api_port"] = port_;
        out["app_shell_5173"] = try_http_get_localhost(5173, "/");
        out["api_health"] = try_http_get_localhost(port_, "/v1/health");
        const json models = load_models_registry();
        const std::string sel = models.value("selected_model", "");
        out["selected_model_id"] = sel;
        for (const auto& m : models["models"]) {
            if (!m.is_object() || m.value("id", "") != sel) {
                continue;
            }
            const std::string p = m.value("path", "");
            const auto resolved = resolve_registry_model_path(p);
            out["model_path"] = resolved.string();
            out["model_analysis"] = analyze_model_path_fs(resolved, to_lower_copy(m.value("format", "")));
            break;
        }
        std::string last;
        if (std::filesystem::exists(last_error_log_path())) {
            std::ifstream fin(last_error_log_path().string());
            std::stringstream buf;
            buf << fin.rdbuf();
            last = buf.str();
        }
        if (last.size() > 2000) {
            last = last.substr(0, 2000) + "...";
        }
        out["last_error"] = last.empty() ? json(nullptr) : json(last);
        set_json_response(res, out);
    } catch (const std::exception& e) {
        set_error_response(res, 500, "readiness_failed", e.what());
    }
}

void RestAPIServer::handle_cli_model_validate(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        std::string id = trim_copy(body.value("id", ""));
        json models = load_models_registry();
        if (id.empty()) {
            id = models.value("selected_model", "");
        }
        for (const auto& m : models["models"]) {
            if (!m.is_object() || m.value("id", "") != id) {
                continue;
            }
            const auto resolved = resolve_registry_model_path(m.value("path", ""));
            json out = {
                {"success", true},
                {"id", id},
                {"path", resolved.string()},
                {"analysis", analyze_model_path_fs(resolved, to_lower_copy(m.value("format", "")))}
            };
            set_json_response(res, out);
            return;
        }
        set_error_response(res, 404, "model_not_found", "Model not found: " + id);
    } catch (const json::exception& e) {
        set_error_response(res, 400, "invalid_json", e.what());
    } catch (const std::exception& e) {
        set_error_response(res, 500, "model_validate_failed", e.what());
    }
}

void RestAPIServer::handle_cli_backend_probe(const httplib::Request&, httplib::Response& res) {
    json r = { {"ok", true}, {"v1_health_check", try_http_get_localhost(port_, "/v1/health")} };
    set_json_response(res, r);
}

void RestAPIServer::handle_cli_stack_restart(const httplib::Request&, httplib::Response& res) {
    try {
        if (!std::filesystem::exists(restart_stack_script_path())) {
            set_error_response(
                res,
                500,
                "restart_stack_script_missing",
                "restart_stack.ps1 not found in project root."
            );
            return;
        }
        const std::string root = project_root_path().string();
        const std::string script = restart_stack_script_path().string();
        set_json_response(res, json({ {"success", true}, {"note", "Full stack restart scheduled (backend + app shell)."} }));
        std::thread([root, script]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            std::string cmd =
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File \"" + script + "\"";
            STARTUPINFOA si{};
            si.cb = sizeof(si);
            PROCESS_INFORMATION pi{};
            std::vector<char> cmdline(cmd.begin(), cmd.end());
            cmdline.push_back('\0');
            CreateProcessA(
                nullptr,
                cmdline.data(),
                nullptr,
                nullptr,
                FALSE,
                0,
                nullptr,
                root.c_str(),
                &si,
                &pi);
            if (pi.hThread) {
                CloseHandle(pi.hThread);
            }
            if (pi.hProcess) {
                CloseHandle(pi.hProcess);
            }
        }).detach();
    } catch (const std::exception& e) {
        set_error_response(res, 500, "stack_restart_failed", e.what());
    }
}

void RestAPIServer::handle_cli_metrics_recommendation(const httplib::Request&, httplib::Response& res) {
    try {
        const auto records = read_all_metrics_records();
        std::map<std::string, std::vector<double>> tps;
        for (const auto& r : records) {
            if (!r.is_object() || !r.contains("device") || !r.contains("throughput_tok_s")) {
                continue;
            }
            const std::string dev = r["device"].get<std::string>();
            if (!r["throughput_tok_s"].is_number()) {
                continue;
            }
            const double v = r["throughput_tok_s"].get<double>();
            if (v > 0) {
                tps[dev].push_back(v);
            }
        }
        std::string best;
        double best_avg = -1.0;
        json detail = json::object();
        for (const auto& e : tps) {
            double s = 0.0;
            for (double x : e.second) {
                s += x;
            }
            const double avg = e.second.empty() ? 0.0 : s / static_cast<double>(e.second.size());
            detail[e.first] = { {"count", e.second.size()}, {"avg_throughput", avg} };
            if (avg > best_avg) {
                best_avg = avg;
                best = e.first;
            }
        }
        json out;
        if (best.empty()) {
            out["suggested_device"] = nullptr;
            out["avg_throughput"] = 0.0;
        } else {
            out["suggested_device"] = best;
            out["avg_throughput"] = best_avg;
        }
        out["by_device"] = detail;
        set_json_response(res, out);
    } catch (const std::exception& e) {
        set_error_response(res, 500, "recommendation_failed", e.what());
    }
}

void RestAPIServer::handle_cli_models_discover(const httplib::Request&, httplib::Response& res) {
    try {
        const json models = load_models_registry();
        std::set<std::string> known;
        const std::filesystem::path models_base = (project_root_path() / "models").lexically_normal();
        for (const auto& m : models["models"]) {
            if (!m.is_object()) {
                continue;
            }
            const std::string p = m.value("path", "");
            std::string rest;
            if (p.rfind("./models/", 0) == 0) {
                rest = p.substr(9);
            } else if (p.rfind("models/", 0) == 0) {
                rest = p.substr(7);
            } else {
                const auto abs = resolve_registry_model_path(p);
                std::error_code ec;
                if (abs.empty() || !std::filesystem::exists(abs, ec)) {
                    continue;
                }
                try {
                    std::string child;
                    if (std::filesystem::is_directory(abs, ec)) {
                        const auto rel = std::filesystem::relative(abs, models_base, ec);
                        if (!ec) {
                            child = rel.string();
                        }
                    } else {
                        const auto rel = std::filesystem::relative(abs.parent_path(), models_base, ec);
                        if (!ec) {
                            child = rel.string();
                        }
                    }
                    if (!child.empty()) {
                        const size_t nxt = child.find_first_of("/\\");
                        if (nxt == std::string::npos) {
                            known.insert(child);
                        } else {
                            known.insert(child.substr(0, nxt));
                        }
                    }
                } catch (...) {
                }
                continue;
            }
            if (!rest.empty()) {
                const size_t nxt = rest.find_first_of("/\\");
                if (nxt == std::string::npos) {
                    known.insert(rest);
                } else {
                    known.insert(rest.substr(0, nxt));
                }
            }
        }
        json arr = json::array();
        std::error_code ec;
        if (std::filesystem::exists(models_base, ec) && std::filesystem::is_directory(models_base, ec)) {
            for (const auto& e : std::filesystem::directory_iterator(models_base, ec)) {
                if (!e.is_directory()) {
                    continue;
                }
                const std::string name = e.path().filename().string();
                if (known.find(name) == known.end()) {
                    arr.push_back({ {"folder", name}, {"path", "./models/" + name} });
                }
            }
        }
        set_json_response(res, { {"unregistered", arr} });
    } catch (const std::exception& e) {
        set_error_response(res, 500, "discover_failed", e.what());
    }
}

void RestAPIServer::handle_cli_diagnostics_export(const httplib::Request&, httplib::Response& res) {
    try {
        const std::filesystem::path root = project_root_path();
        const std::filesystem::path script = root / "Export-Diagnostics.ps1";
        if (!std::filesystem::exists(script)) {
            set_error_response(
                res,
                500,
                "export_script_missing",
                "Export-Diagnostics.ps1 not found in project root."
            );
            return;
        }
        const std::string cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + script.string() + "\"";
        const int r = std::system(cmd.c_str());
        (void)r;
        const std::filesystem::path marker = root / "export" / "last-export.txt";
        if (!std::filesystem::exists(marker)) {
            set_error_response(
                res,
                500,
                "export_failed",
                "Diagnostics export did not produce export/last-export.txt. Run .\\Export-Diagnostics.ps1 manually."
            );
            return;
        }
        std::ifstream fin(marker.string());
        std::string p;
        std::getline(fin, p);
        set_json_response(res, { {"success", true}, {"zip_path", p} });
    } catch (const std::exception& e) {
        set_error_response(res, 500, "export_exception", e.what());
    }
}

