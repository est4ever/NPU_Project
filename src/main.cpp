#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include "../OpenVINO/Backend/BackendPool.h"
#include "../OpenVINO/Backend/KVCacheMonitor.h"
#include "../OpenVINO/Scheduler/OpenVINOScheduler.h"
#include "SpeculativeEngine.h"
#include "RestAPIServer.h"

#include <chrono>
#include <iostream>
#include <string>
#include <fstream>
#include <filesystem>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <sstream>
#include <iomanip>
#include <cctype>
#include <limits>
#include <algorithm>
#include <cmath>
#include <thread>

// Static initialization debug - writes to file before main() is called
namespace {
    struct DebugInit {
        DebugInit() {
            std::ofstream f("debug_init.txt");
            f << "Global initialization reached at module load\n";
            f.flush();
        }
    } debug_instance;
}

// Append logs to runlog.txt (handy when dist runs outside VSCode)
static void logline(const std::string& s) {
    std::ofstream f("runlog.txt", std::ios::app);
    f << s << std::endl;
}

// Strip one layer of wrapping quotes (common when paths are copy-pasted into JSON or shells).
static std::string strip_wrapping_quotes(std::string s) {
    while (s.size() >= 2) {
        const char a = s.front();
        const char b = s.back();
        if ((a == '"' && b == '"') || (a == '\'' && b == '\'')) {
            s = s.substr(1, s.size() - 2);
            continue;
        }
        break;
    }
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front())) != 0) {
        s.erase(s.begin());
    }
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back())) != 0) {
        s.pop_back();
    }
    return s;
}

// Forward declarations for argument parsing functions
static bool parse_int_arg(int argc, char** argv, const std::string& flag, int& out);
static bool parse_double_arg(int argc, char** argv, const std::string& flag, double& out);

static void print_help() {
    std::cout << "\n=== NPU_Project Interactive Commands ===\n\n";
    std::cout << "Available Commands:\n";
    std::cout << "  help                Show this help message\n";
    std::cout << "  exit                Exit the program\n";
    std::cout << "  stats               Show performance metrics (TTFT, TPOT, throughput)\n";
    std::cout << "  memory              Show current RAM/VRAM usage\n";
    std::cout << "  devices             List all loaded devices\n";
    std::cout << "  switch <device>     Switch to a different device (CPU/GPU/NPU)\n";
    std::cout << "  auto                Toggle automatic device switching on/off\n";
    std::cout << "\nCommand-Line Flags:\n";
    std::cout << "  --policy PERFORMANCE|BATTERY_SAVER|BALANCED  Set device selection policy\n";
    std::cout << "  --device CPU|GPU|NPU                         Override device selection\n";
    std::cout << "  --benchmark                                   Run benchmarks and load on all devices\n";
    std::cout << "  --json                                        Emit NDJSON metrics to stderr\n";
    std::cout << "  --server                                      Start OpenAI-compatible REST API server\n";
    std::cout << "  --port N                                      Server port (default: 8080)\n";
    std::cout << "  --context-routing                             Enable context-aware device routing\n";
    std::cout << "  --optimize-memory                             Enable INT8 KV-cache quantization (50-75% RAM savings)\n";
    std::cout << "  --split-prefill                               Route long prompts to best TTFT device\n";
    std::cout << "  --prefill-threshold N                         Prompt token threshold (default 256)\n";
    std::cout << "  --calibrate-prefill                           Recommend a prefill threshold and exit\n";
    std::cout << "  --speculative                                 Enable speculative decoding\n";
    std::cout << "  --draft-model PATH                            Draft model path (default: <model>-draft)\n";
    std::cout << "  --draft-device DEVICE                         Draft device (default: policy)\n";
    std::cout << "  --verify-device DEVICE                        Verify device (default: policy)\n";
    std::cout << "  --draft-k N                                   Draft tokens per block (default 4)\n";
    std::cout << "  --min-accept X                                Min accept rate before disabling (default 0.55)\n";
    std::cout << "  --spec-disable-on-low-accept                  Disable speculative on low accept rate\n";
    std::cout << "\nExamples:\n";
    std::cout << "  .\\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE\n";
    std::cout << "  .\\run.ps1 ./models/Qwen2.5-0.5B-Instruct --benchmark\n";
    std::cout << "  .\\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --port 8080\n";
    std::cout << "  .\\run.ps1 ./models/Qwen2.5-0.5B-Instruct --context-routing --optimize-memory\n";
    std::cout << "  .\\run.ps1 ./models/Qwen2.5-0.5B-Instruct --speculative --draft-device NPU\n";
    std::cout << "\n";
}

static EnginePolicy parse_policy_arg(int argc, char** argv) {
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--policy") {
            if (i + 1 < argc) {
                std::string policy = argv[i + 1];
                if (policy == "PERFORMANCE") return EnginePolicy::PERFORMANCE;
                if (policy == "BATTERY_SAVER") return EnginePolicy::BATTERY_SAVER;
                if (policy == "BALANCED") return EnginePolicy::BALANCED;
            }
        }
    }
    return EnginePolicy::BATTERY_SAVER; // Default to battery saver (NPU-first)
}

static bool parse_device_override(int argc, char** argv, std::string& out) {
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--device") {
            if (i + 1 < argc) {
                out = argv[i + 1];
                return true;
            }
            out.clear();
            return true;
        }
        const std::string prefix = "--device=";
        if (arg.rfind(prefix, 0) == 0) {
            out = arg.substr(prefix.size());
            return true;
        }
    }
    out.clear();
    return false;
}

static bool has_benchmark_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--benchmark") {
            return true;
        }
    }
    return false;
}

static bool has_json_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--json") {
            return true;
        }
    }
    return false;
}

static bool has_speculative_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--speculative") {
            return true;
        }
    }
    return false;
}

static bool has_split_prefill_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--split-prefill") {
            return true;
        }
    }
    return false;
}

static bool has_calibrate_prefill_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--calibrate-prefill") {
            return true;
        }
    }
    return false;
}

static bool has_spec_disable_on_low_accept_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--spec-disable-on-low-accept") {
            return true;
        }
    }
    return false;
}

static bool has_server_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--server") {
            return true;
        }
    }
    return false;
}

static bool has_preload_all_devices_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--preload-all-devices") {
            return true;
        }
    }
    return false;
}

static int parse_server_port(int argc, char** argv) {
    int port = 8080;  // Default
    parse_int_arg(argc, argv, "--port", port);
    return port;
}

static bool has_kv_paging_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--optimize-memory") {
            return true;
        }
    }
    return false;
}

static bool has_context_routing_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--context-routing") {
            return true;
        }
    }
    return false;
}

static bool parse_int_arg(int argc, char** argv, const std::string& flag, int& out) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == flag) {
            if (i + 1 < argc) {
                out = std::atoi(argv[i + 1]);
                return true;
            }
            return false;
        }
        const std::string prefix = flag + "=";
        if (arg.rfind(prefix, 0) == 0) {
            out = std::atoi(arg.substr(prefix.size()).c_str());
            return true;
        }
    }
    return true;
}

static bool parse_double_arg(int argc, char** argv, const std::string& flag, double& out) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == flag) {
            if (i + 1 < argc) {
                out = std::atof(argv[i + 1]);
                return true;
            }
            return false;
        }
        const std::string prefix = flag + "=";
        if (arg.rfind(prefix, 0) == 0) {
            out = std::atof(arg.substr(prefix.size()).c_str());
            return true;
        }
    }
    return true;
}

static bool parse_string_arg(int argc, char** argv, const std::string& flag, std::string& out) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == flag) {
            if (i + 1 < argc) {
                out = argv[i + 1];
                return true;
            }
            return false;
        }
        const std::string prefix = flag + "=";
        if (arg.rfind(prefix, 0) == 0) {
            out = arg.substr(prefix.size());
            return true;
        }
    }
    return true;
}

static int64_t estimate_prompt_tokens(const std::string& prompt) {
    int64_t count = 0;
    bool in_token = false;
    for (unsigned char c : prompt) {
        if (std::isspace(c)) {
            if (in_token) {
                ++count;
                in_token = false;
            }
        } else {
            in_token = true;
        }
    }
    if (in_token) {
        ++count;
    }
    return count;
}

static std::string build_synthetic_prompt(int64_t tokens) {
    if (tokens <= 0) {
        return "";
    }
    std::string prompt;
    prompt.reserve(static_cast<size_t>(tokens) * 5);
    for (int64_t i = 0; i < tokens; ++i) {
        prompt += "word ";
    }
    return prompt;
}

static bool is_device_available(const std::vector<std::string>& available, const std::string& device) {
    return std::find(available.begin(), available.end(), device) != available.end();
}

static std::string profile_for_policy(EnginePolicy policy) {
    switch (policy) {
        case EnginePolicy::PERFORMANCE: return "balanced-performance";
        case EnginePolicy::BATTERY_SAVER: return "latency-first";
        case EnginePolicy::BALANCED:
        default: return "default";
    }
}

static std::string select_best_ttft_device(
    const std::map<std::string, DeviceBenchmark>& benchmarks,
    const std::vector<std::string>& loaded_devices,
    const std::string& fallback
) {
    double best_ttft = std::numeric_limits<double>::max();
    std::string best_device = fallback;
    for (const auto& [device, bench] : benchmarks) {
        if (!bench.success) continue;
        if (!is_device_available(loaded_devices, device)) continue;
        if (bench.ttft_ms < best_ttft) {
            best_ttft = bench.ttft_ms;
            best_device = device;
        }
    }
    return best_device;
}

static std::string select_best_throughput_device(
    const std::map<std::string, DeviceBenchmark>& benchmarks,
    const std::vector<std::string>& loaded_devices,
    const std::string& fallback
) {
    double best_throughput = -1.0;
    std::string best_device = fallback;
    for (const auto& [device, bench] : benchmarks) {
        if (!bench.success) continue;
        if (!is_device_available(loaded_devices, device)) continue;
        if (bench.tokens_per_sec > best_throughput) {
            best_throughput = bench.tokens_per_sec;
            best_device = device;
        }
    }
    return best_device;
}

static int64_t get_epoch_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

static std::string resolve_token_count_source(const BackendMetrics& metrics) {
    bool any_estimated = (metrics.prompt_tokens_source == TokenCountSource::Estimated) ||
        (metrics.generated_tokens_source == TokenCountSource::Estimated);
    bool any_native = (metrics.prompt_tokens_source == TokenCountSource::OpenVinoNative) ||
        (metrics.generated_tokens_source == TokenCountSource::OpenVinoNative);

    if (any_estimated) {
        return "estimated";
    }
    if (any_native) {
        return "openvino_native";
    }
    return "unknown";
}

static std::string json_escape(const std::string& input) {
    std::string out;
    out.reserve(input.size());
    for (char c : input) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    std::ostringstream oss;
                    oss << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << static_cast<int>(static_cast<unsigned char>(c));
                    out += oss.str();
                } else {
                    out += c;
                }
        }
    }
    return out;
}

struct SpeculativeContext {
    bool requested = false;
    bool active = false;
    int draft_k = 0;
    std::string draft_model;
    std::string draft_device;
    std::string verify_device;
    std::optional<double> accept_rate;
    std::optional<int64_t> accepted_tokens;
    std::optional<int64_t> proposed_tokens;
    std::optional<std::string> disabled_reason;
};

static void emit_json_metrics(
    std::ostream& os,
    const std::string& model_name,
    const std::string& device,
    EnginePolicy policy,
    const BackendMetrics& metrics,
    double total_ms,
    bool fallback_used,
    const std::optional<std::string>& error_message,
    const SpeculativeContext& spec
) {
    std::ostringstream line;
    line.setf(std::ios::fixed);
    line << std::setprecision(3);

    const int schema_version = 1;
    const int64_t ts_ms = get_epoch_ms();
    std::optional<double> native_throughput;
    std::optional<double> derived_throughput;
    std::optional<bool> throughput_derived;

    if (metrics.valid) {
        native_throughput = metrics.throughput;
    }

    if (metrics.generated_tokens.has_value() && total_ms > 0.0) {
        derived_throughput = static_cast<double>(metrics.generated_tokens.value()) / (total_ms / 1000.0);
    }

    std::optional<double> chosen_throughput = native_throughput;
    if (!chosen_throughput.has_value() && derived_throughput.has_value()) {
        chosen_throughput = derived_throughput;
        throughput_derived = true;
    } else if (chosen_throughput.has_value() && derived_throughput.has_value()) {
        double denom = std::max(0.001, chosen_throughput.value());
        double diff_ratio = std::abs(derived_throughput.value() - chosen_throughput.value()) / denom;
        if (diff_ratio > 0.2) {
            throughput_derived = false;
        } else {
            throughput_derived = false;
        }
    } else if (chosen_throughput.has_value()) {
        throughput_derived = false;
    }

    line << "{\"schema\":" << schema_version
         << ",\"ts\":" << ts_ms
         << ",\"model\":\"" << json_escape(model_name)
         << "\",\"device\":\"" << json_escape(device)
         << "\",\"policy\":\"" << policy_to_string(policy) << "\",";

    if (metrics.valid) {
        line << "\"ttft_ms\":" << metrics.ttft_ms
             << ",\"tpot_ms\":" << metrics.tpot_ms << ",";
    } else {
        line << "\"ttft_ms\":null,\"tpot_ms\":null,";
    }

    if (chosen_throughput.has_value()) {
        line << "\"throughput_tok_s\":" << chosen_throughput.value() << ",";
    } else {
        line << "\"throughput_tok_s\":null,";
    }

    line << "\"total_ms\":" << total_ms << ",";

    if (metrics.prompt_tokens.has_value()) {
        line << "\"prompt_tokens\":" << metrics.prompt_tokens.value() << ",";
    } else {
        line << "\"prompt_tokens\":null,";
    }

    if (metrics.generated_tokens.has_value()) {
        line << "\"generated_tokens\":" << metrics.generated_tokens.value() << ",";
    } else {
        line << "\"generated_tokens\":null,";
    }

    line << "\"token_count_source\":\"" << resolve_token_count_source(metrics) << "\",";

    if (throughput_derived.has_value()) {
        line << "\"throughput_derived\":" << (throughput_derived.value() ? "true" : "false") << ",";
    } else {
        line << "\"throughput_derived\":null,";
    }

    line << "\"fallback_used\":" << (fallback_used ? "true" : "false") << ",";

    if (error_message.has_value()) {
        line << "\"error\":\"" << json_escape(error_message.value()) << "\"";
    } else {
        line << "\"error\":null";
    }

    line << ",\"speculative_requested\":" << (spec.requested ? "true" : "false")
         << ",\"speculative_active\":" << (spec.active ? "true" : "false") << ",";

    if (spec.draft_k > 0) {
        line << "\"draft_k\":" << spec.draft_k << ",";
    } else {
        line << "\"draft_k\":null,";
    }

    if (!spec.draft_model.empty()) {
        line << "\"draft_model\":\"" << json_escape(spec.draft_model) << "\",";
    } else {
        line << "\"draft_model\":null,";
    }

    if (!spec.draft_device.empty()) {
        line << "\"draft_device\":\"" << json_escape(spec.draft_device) << "\",";
    } else {
        line << "\"draft_device\":null,";
    }

    if (!spec.verify_device.empty()) {
        line << "\"verify_device\":\"" << json_escape(spec.verify_device) << "\",";
    } else {
        line << "\"verify_device\":null,";
    }

    if (spec.accept_rate.has_value()) {
        line << "\"accept_rate\":" << spec.accept_rate.value() << ",";
    } else {
        line << "\"accept_rate\":null,";
    }

    if (spec.accepted_tokens.has_value()) {
        line << "\"accepted_tokens\":" << spec.accepted_tokens.value() << ",";
    } else {
        line << "\"accepted_tokens\":null,";
    }

    if (spec.proposed_tokens.has_value()) {
        line << "\"proposed_tokens\":" << spec.proposed_tokens.value() << ",";
    } else {
        line << "\"proposed_tokens\":null,";
    }

    if (spec.disabled_reason.has_value()) {
        line << "\"spec_disabled_reason\":\"" << json_escape(spec.disabled_reason.value()) << "\"";
    } else {
        line << "\"spec_disabled_reason\":null";
    }

    line << "}";
    os << line.str() << "\n";
    os.flush();
}

static void emit_metrics_if_enabled(
    bool json_mode,
    std::ostream& os,
    const std::string& model_name,
    const std::string& device,
    EnginePolicy policy,
    const BackendMetrics& metrics,
    double total_ms,
    bool fallback_used,
    const std::optional<std::string>& error_message,
    const SpeculativeContext& spec
) {
    if (!json_mode) {
        return;
    }
    emit_json_metrics(os, model_name, device, policy, metrics, total_ms, fallback_used, error_message, spec);
}

int main(int argc, char** argv) {
    // Disable output buffering
    std::cout.setf(std::ios::unitbuf);
    std::cerr.setf(std::ios::unitbuf);
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    
    std::cout << "=== PROGRAM STARTED ===" << std::endl;
    
    // Check command line arguments
    if (argc < 2) {
        std::cerr << "Usage: npu_wrapper.exe <model_path> [options]\n";
        std::cerr << "\nOptions:\n";
        std::cerr << "  --policy PERFORMANCE|BATTERY_SAVER|BALANCED  Set device selection policy\n";
        std::cerr << "  --device CPU|GPU|NPU                         Override device selection\n";
        std::cerr << "  --benchmark                                   Run benchmarks and load on all devices\n";
        std::cerr << "  --json                                        Emit NDJSON metrics to stderr\n";
        std::cerr << "  --server                                      Start OpenAI-compatible REST API server\n";
        std::cerr << "  --port N                                      Server port (default: 8080)\n";
        std::cerr << "  --preload-all-devices                         Load model on all devices at startup (slower startup, instant switching)\n";
        std::cerr << "  --context-routing                             Enable context-aware device routing\n";
        std::cerr << "  --optimize-memory                             Enable INT8 KV-cache quantization (50-75% RAM savings)\n";
        std::cerr << "  --split-prefill                               Route long prompts to best TTFT device\n";
        std::cerr << "  --prefill-threshold N                         Prompt token threshold (default 256)\n";
        std::cerr << "  --calibrate-prefill                           Recommend a prefill threshold and exit\n";
        std::cerr << "  --speculative                                 Enable speculative decoding (scaffold)\n";
        std::cerr << "  --draft-model PATH                            Draft model path (default: <model>-draft)\n";
        std::cerr << "  --draft-device DEVICE                         Draft device (default: policy)\n";
        std::cerr << "  --verify-device DEVICE                        Verify device (default: policy)\n";
        std::cerr << "  --draft-k N                                   Draft tokens per block (default 4)\n";
        std::cerr << "  --min-accept X                                Min accept rate before disabling (default 0.55)\n";
        std::cerr << "  --spec-disable-on-low-accept                   Disable speculative on low accept rate\n";
        std::cerr << "\nExamples:\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy BATTERY_SAVER\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device NPU\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --benchmark\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --server --port 8080\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --context-routing --optimize-memory\n";
        return 1;
    }

    // Proves which binary is running (useful when you have build/ vs dist/)
    char exePath[MAX_PATH]{0};
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);

    logline("=== RUN START ===");
    logline(std::string("EXE: ") + exePath);

    std::cout << "MAIN STARTED\n" << std::flush;
    logline("MAIN STARTED");

    // Speculative decoding (scaffold only)
    bool speculative_mode = has_speculative_flag(argc, argv);
    int draft_k = 4;
    double min_accept = 0.55;
    bool spec_disable_on_low_accept = has_spec_disable_on_low_accept_flag(argc, argv);

    std::string model_dir = strip_wrapping_quotes(argv[1]);
    std::string model_name = std::filesystem::path(model_dir).filename().string();
    std::string draft_model_dir;
    std::string draft_device;
    std::string verify_device;
    if (!parse_string_arg(argc, argv, "--draft-model", draft_model_dir)) {
        std::cerr << "Error: --draft-model requires a value\n";
        return 1;
    }
    draft_model_dir = strip_wrapping_quotes(draft_model_dir);
    if (!parse_string_arg(argc, argv, "--draft-device", draft_device)) {
        std::cerr << "Error: --draft-device requires a value\n";
        return 1;
    }
    if (!parse_string_arg(argc, argv, "--verify-device", verify_device)) {
        std::cerr << "Error: --verify-device requires a value\n";
        return 1;
    }
    if (!parse_int_arg(argc, argv, "--draft-k", draft_k) || draft_k <= 0) {
        std::cerr << "Error: --draft-k requires a positive integer\n";
        return 1;
    }
    if (!parse_double_arg(argc, argv, "--min-accept", min_accept) || min_accept <= 0.0 || min_accept > 1.0) {
        std::cerr << "Error: --min-accept requires a value in (0, 1]\n";
        return 1;
    }
    if (speculative_mode) {
        if (draft_model_dir.empty()) {
            draft_model_dir = model_dir + "-draft";
        }
        if (draft_device.empty()) {
            draft_device = "NPU";
        }
    }
    std::cout << "Model dir: " << model_dir << "\n" << std::flush;
    logline("Model dir: " + model_dir);

    // Initialize scheduler
    OpenVINOScheduler scheduler;
    
    // Check for policy argument
    EnginePolicy policy = parse_policy_arg(argc, argv);
    std::cout << "Policy: " << (policy == EnginePolicy::PERFORMANCE ? "PERFORMANCE" : 
                                   policy == EnginePolicy::BATTERY_SAVER ? "BATTERY_SAVER" : "BALANCED") << "\n" << std::flush;
    logline("Policy: ");
    _putenv_s("LOOMIS_PERF_MODE", profile_for_policy(policy).c_str());
    
    // Check for benchmark mode
    bool benchmark_mode = has_benchmark_flag(argc, argv);

    // Check for JSON output mode
    bool json_mode = has_json_flag(argc, argv);

    // Calibrate prefill threshold and exit
    bool calibrate_prefill = has_calibrate_prefill_flag(argc, argv);

    // Split prefill vs decode routing
    bool split_prefill = has_split_prefill_flag(argc, argv);
    int prefill_threshold = 256;
    if (!parse_int_arg(argc, argv, "--prefill-threshold", prefill_threshold) || prefill_threshold <= 0) {
        std::cerr << "Error: --prefill-threshold requires a positive integer\n";
        return 1;
    }
    
    // Check for device override
    std::string device_override;
    bool device_arg_found = parse_device_override(argc, argv, device_override);
    if (device_arg_found && device_override.empty()) {
        std::cerr << "Error: --device requires a value (CPU|GPU|NPU)\n";
        return 1;
    }
    
    // Check for server mode
    bool server_mode = has_server_flag(argc, argv);
    int server_port = parse_server_port(argc, argv);
    
    // Check for preload all devices flag (server mode only)
    bool preload_all_devices = has_preload_all_devices_flag(argc, argv);
    
    // Check for KV-cache monitoring features
    bool enable_kv_paging = has_kv_paging_flag(argc, argv);
    bool context_routing = has_context_routing_flag(argc, argv);
    
    // Initialize KV-cache monitor
    KVCacheMonitor kv_monitor;
    if (enable_kv_paging) {
        kv_monitor.set_disk_paging_enabled(true, "./kv_cache_paging");
    }
    
    // Print initial memory status
    if (context_routing || enable_kv_paging) {
        kv_monitor.print_memory_status();
    }
    if (speculative_mode && !device_override.empty()) {
        if (verify_device.empty()) {
            verify_device = device_override;
        }
        device_override.clear();
    }
    if (!device_override.empty() && split_prefill) {
        std::cout << "[Split] --device override provided; disabling split-prefill mode.\n";
        split_prefill = false;
    }
    if (speculative_mode && split_prefill) {
        std::cout << "[Speculative] Split-prefill disabled while speculative decoding is active.\n";
        split_prefill = false;
    }

    if (calibrate_prefill) {
        std::cout << "[Calibrate] Running prefill threshold calibration...\n";
        auto available_devices = scheduler.discover_devices();
        std::vector<std::string> devices_to_test;
        for (const auto& dev : available_devices) {
            if (dev == "CPU" || dev == "GPU" || dev == "NPU") {
                devices_to_test.push_back(dev);
            }
        }

        if (devices_to_test.empty()) {
            std::cerr << "[Calibrate] No supported devices found (CPU/GPU/NPU).\n";
            return 1;
        }

        auto throughput_bench = scheduler.benchmark_devices(model_dir, devices_to_test);
        std::string throughput_device = select_best_throughput_device(
            throughput_bench,
            devices_to_test,
            devices_to_test.front()
        );

        std::vector<int64_t> lengths = {64, 256, 1024};
        std::string prefill_device = throughput_device;
        int recommended_threshold = prefill_threshold;
        std::string compare_device = is_device_available(devices_to_test, "NPU") ? "NPU" : "CPU";
        bool gpu_available = is_device_available(devices_to_test, "GPU");
        std::string best_ttft_device;

        for (int64_t len : lengths) {
            std::string prompt = build_synthetic_prompt(len);
            auto ttft_map = scheduler.benchmark_ttft_for_prompt(model_dir, devices_to_test, prompt, 1);

            double best_ttft = std::numeric_limits<double>::max();
            std::string best_device = devices_to_test.front();
            for (const auto& [device, ttft] : ttft_map) {
                if (ttft < best_ttft) {
                    best_ttft = ttft;
                    best_device = device;
                }
            }
            best_ttft_device = best_device;

            if (gpu_available && ttft_map.find("GPU") != ttft_map.end()) {
                auto compare_it = ttft_map.find(compare_device);
                if (compare_it != ttft_map.end()) {
                    double gpu_ttft = ttft_map["GPU"];
                    double compare_ttft = compare_it->second;
                    if (gpu_ttft < compare_ttft * 0.9) {
                        prefill_device = "GPU";
                        recommended_threshold = static_cast<int>(len);
                        break;
                    }
                }
            }
        }

        if (!gpu_available) {
            prefill_device = best_ttft_device.empty() ? throughput_device : best_ttft_device;
        } else if (prefill_device != "GPU") {
            prefill_device = best_ttft_device.empty() ? throughput_device : best_ttft_device;
        }

        std::cout << "[Calibrate] Recommended prefill threshold: " << recommended_threshold << " tokens\n";
        std::cout << "[Calibrate] Prefill device: " << prefill_device
                  << ", Decode device: " << throughput_device << "\n";
        return 0;
    }

    try {
        if (benchmark_mode) {
            // ============ MULTI-DEVICE MODE ============
            std::cout << "\n[MULTI-DEVICE MODE ENABLED]\n";
            logline("Multi-device mode enabled");
            
            // Get all available devices
            auto available_devices = scheduler.discover_devices();
            
            // Filter devices to test (skip AUTO, HETERO, etc.)
            std::vector<std::string> devices_to_test;
            for (const auto& dev : available_devices) {
                if (dev == "CPU" || dev == "GPU" || dev == "NPU") {
                    devices_to_test.push_back(dev);
                }
            }
            
            // Run benchmarks
            auto benchmarks = scheduler.benchmark_devices(model_dir, devices_to_test);
            
            // Get best device based on benchmarks
            std::string best_device = scheduler.get_best_device_from_benchmarks(benchmarks, policy);

            if (speculative_mode) {
                if (verify_device.empty()) {
                    verify_device = best_device;
                }
                if (draft_device.empty()) {
                    draft_device = verify_device;
                }
                if (verify_device != best_device) {
                    std::cout << "[Speculative] Verify device requested: " << verify_device << "\n";
                    best_device = verify_device;
                }
            }
            
            BackendPool pool;
            SpeculativeEngine spec_engine;
            bool spec_ready = false;

            std::string ttft_device = best_device;
            std::string throughput_device = best_device;
            int prefill_threshold_high = prefill_threshold;
            int prefill_threshold_low = std::max(1, static_cast<int>(prefill_threshold * 0.8));
            bool use_prefill_device = false;
            std::vector<std::string> loaded_devices;

            if (!speculative_mode) {
                // Load model on all tested devices
                pool.load_on_devices(model_dir, devices_to_test);
                pool.set_active_device(best_device);
                loaded_devices = pool.get_loaded_devices();

                if (split_prefill) {
                    ttft_device = select_best_ttft_device(benchmarks, loaded_devices, best_device);
                    throughput_device = select_best_throughput_device(benchmarks, loaded_devices, best_device);
                    std::cout << "[Split] TTFT device: " << ttft_device
                              << ", Throughput device: " << throughput_device
                              << ", Threshold: " << prefill_threshold_high
                              << " (low: " << prefill_threshold_low << ") tokens\n";
                }
            } else {
                std::cout << "[Speculative] Draft model: " << draft_model_dir << "\n";
                std::cout << "[Speculative] Draft device: " << draft_device
                          << ", Verify device: " << verify_device << "\n";
                spec_engine.load_models(draft_model_dir, draft_device, model_dir, verify_device);
                spec_ready = true;
            }
            
            // SERVER MODE: Start REST API server instead of interactive loop
            if (server_mode) {
                std::cout << "\n[Server Mode] Starting OpenAI-compatible REST API server...\n";
                std::cout << "[Server Mode] Backend: " << pool.get_active_device() << "\n";
                if (context_routing) {
                    std::cout << "[Server Mode] Context-aware routing: ENABLED\n";
                }
                if (enable_kv_paging) {
                    std::cout << "[Server Mode] INT8 KV-cache optimization: ENABLED\n";
                }

                RuntimeConfig server_config;
                server_config.set_policy(policy);
                server_config.set_performance_profile(profile_for_policy(policy), "policy-selected");
                server_config.set_json_mode(json_mode);
                server_config.set_split_prefill(split_prefill);
                server_config.set_context_routing(context_routing);
                server_config.set_enable_kv_paging(enable_kv_paging);
                server_config.set_prefill_threshold_high(prefill_threshold_high);

                save_npu_launch_state(argc, argv);
                RestAPIServer api_server(&pool, &server_config, &kv_monitor, server_port);
                
                // Start server in a separate thread with exception handling
                std::thread server_thread([&api_server]() {
                    try {
                        api_server.start();
                    } catch (const std::exception& e) {
                        std::cerr << "[Thread] Server thread exception: " << e.what() << "\n";
                        std::cerr.flush();
                    } catch (...) {
                        std::cerr << "[Thread] Server thread unknown exception\n";
                        std::cerr.flush();
                    }
                });
                
                std::cout << "\n[Server Mode] Server running. Press Ctrl+C to stop.\n";
                std::cout << "[Server Mode] Test with: curl -X POST http://localhost:" << server_port << "/v1/chat/completions \\\n";
                std::cout << "  -H \"Content-Type: application/json\" \\\n";
                std::cout << "  -d '{\"model\":\"openvino\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'\n\n";
                std::cout.flush();
                
                // Wait for server thread
                server_thread.join();
                
                // Clean up and exit
                logline("=== SERVER MODE END ===");
                return 0;
            }
            
            std::cout << "\nREADY. Type prompt ('help' for commands, 'exit' to quit";
            if (!speculative_mode) {
                std::cout << ", stats/devices/auto/switch [device]";
            }
            std::cout << ")\n" << std::flush;
            logline("READY (multi-device).");
            
            bool auto_switch_enabled = true;  // Auto-switching enabled by default
            if (split_prefill) {
                auto_switch_enabled = false;
                std::cout << "[Split] Auto-switching disabled while split-prefill is active\n";
            }
            
            while (true) {
                if (speculative_mode) {
                    std::cout << "\nYou: " << std::flush;
                } else {
                    std::cout << "\nYou [" << pool.get_active_device() << (auto_switch_enabled ? " AUTO" : "") << "]: " << std::flush;
                }
                std::string prompt;
                if (!std::getline(std::cin, prompt)) break;
                if (prompt == "exit") break;

                if (!speculative_mode) {
                    if (prompt == "help") {
                        print_help();
                        continue;
                    }
                    
                    if (prompt == "stats") {
                        pool.print_stats();
                        continue;
                    }
                    
                    if (prompt == "memory") {
                        kv_monitor.print_memory_status();
                        continue;
                    }
                    
                    // Check for switch command
                    if (prompt.rfind("switch ", 0) == 0) {
                        std::string target_device = prompt.substr(7);
                        pool.set_active_device(target_device);
                        continue;
                    }
                    
                    // Show available devices
                    if (prompt == "devices") {
                        std::cout << "Loaded devices:\n";
                        for (const auto& dev : pool.get_loaded_devices()) {
                            std::cout << "  - " << dev << (dev == pool.get_active_device() ? " (active)" : "") << "\n";
                        }
                        continue;
                    }
                    
                    // Toggle auto-switching
                    if (prompt == "auto") {
                        auto_switch_enabled = !auto_switch_enabled;
                        std::cout << "[Auto-switching " << (auto_switch_enabled ? "ENABLED" : "DISABLED") << "]\n";
                        continue;
                    }
                }
                
                auto start_time = std::chrono::high_resolution_clock::now();
                std::string device_used = speculative_mode ? verify_device : pool.get_active_device();

                SpeculativeContext spec;
                BackendMetrics metrics;
                if (speculative_mode && spec_ready) {
                    SpeculativeRunResult spec_result = spec_engine.generate_stream(
                        prompt,
                        128,
                        draft_k,
                        min_accept,
                        spec_disable_on_low_accept
                    );

                    spec.requested = true;
                    spec.active = spec_result.active;
                    spec.draft_k = draft_k;
                    spec.draft_model = draft_model_dir;
                    spec.draft_device = draft_device;
                    spec.verify_device = verify_device;
                    spec.accept_rate = spec_result.proposed_tokens > 0 ? std::optional<double>(spec_result.accept_rate) : std::nullopt;
                    spec.accepted_tokens = spec_result.accepted_tokens;
                    spec.proposed_tokens = spec_result.proposed_tokens;
                    spec.disabled_reason = spec_result.disabled_reason;

                    metrics = spec_engine.get_last_metrics();
                } else {
                    if (split_prefill) {
                        int64_t prompt_tokens = estimate_prompt_tokens(prompt);
                        if (!use_prefill_device && prompt_tokens >= prefill_threshold_high) {
                            use_prefill_device = true;
                        } else if (use_prefill_device && prompt_tokens <= prefill_threshold_low) {
                            use_prefill_device = false;
                        }
                        std::string target_device = use_prefill_device ? ttft_device : throughput_device;
                        if (pool.get_active_device() != target_device) {
                            pool.set_active_device(target_device);
                        }
                    }

                    device_used = pool.get_active_device();
                    pool.generate_stream(prompt);
                    metrics = pool.get_active_metrics();
                }
                
                auto end_time = std::chrono::high_resolution_clock::now();
                double elapsed = std::chrono::duration<double>(end_time - start_time).count();
                double total_ms = elapsed * 1000.0;
                
                if (!speculative_mode) {
                    std::cout << "\n[Device: " << pool.get_active_device() << ", Time: " << elapsed << " seconds]\n" << std::flush;
                    logline("Generation on " + pool.get_active_device() + ": " + std::to_string(elapsed) + " seconds");
                } else {
                    std::cout << "\n[Speculative Time: " << elapsed << " seconds]\n" << std::flush;
                }

                std::optional<std::string> error_message;
                bool fallback_used = false;
                emit_metrics_if_enabled(
                    json_mode,
                    std::cerr,
                    model_name,
                    device_used,
                    policy,
                    metrics,
                    total_ms,
                    fallback_used,
                    error_message,
                    spec
                );
                
                // Automatic device selection based on performance (if enabled)
                if (!speculative_mode && auto_switch_enabled) {
                    std::string prev_device = pool.get_active_device();
                    std::string new_device = pool.auto_select_best_device(benchmarks);
                    if (new_device != prev_device) {
                        pool.set_active_device(new_device);
                    }
                }
                
                // Check memory status if optimization is enabled
                if (enable_kv_paging && kv_monitor.is_memory_critical(0.90f)) {
                    std::cout << "\n⚠️  [Memory Warning] RAM usage > 90% - Type 'memory' for details\n";
                }
            }
            
        } else {
            // ============ SINGLE-DEVICE MODE ============
            // Get device based on policy or override
            std::string device;
            std::vector<std::string> available_devices;
            std::string prefill_device;
            std::string decode_device;
            int prefill_threshold_high = prefill_threshold;
            int prefill_threshold_low = std::max(1, static_cast<int>(prefill_threshold * 0.8));
            bool use_prefill_device = false;
            SpeculativeEngine spec_engine;
            bool spec_ready = false;
            if (!device_override.empty()) {
                device = device_override;
                std::cout << "Device override: " << device << "\n" << std::flush;
                logline("Device override: " + device);
            } else {
                device = scheduler.get_optimal_device(policy);
            }

            if (speculative_mode) {
                if (verify_device.empty()) {
                    verify_device = device;
                }
                if (draft_device.empty()) {
                    draft_device = verify_device;
                }
                device = verify_device;
                std::cout << "[Speculative] Draft model: " << draft_model_dir << "\n";
                std::cout << "[Speculative] Draft device: " << draft_device
                          << ", Verify device: " << verify_device << "\n";
                spec_engine.load_models(draft_model_dir, draft_device, model_dir, verify_device);
                spec_ready = true;
            }
            std::cout << "Device chosen: " << device << "\n" << std::flush;
            logline("Device chosen: " + device);
            
            // Use BackendPool for single-device mode (maintains abstraction layer)
            BackendPool pool;
            if (!speculative_mode) {
                if (split_prefill) {
                    available_devices = scheduler.discover_devices();
                    prefill_device = is_device_available(available_devices, "GPU") ? "GPU" :
                        (is_device_available(available_devices, "CPU") ? "CPU" : "NPU");
                    decode_device = is_device_available(available_devices, "NPU") ? "NPU" :
                        (is_device_available(available_devices, "GPU") ? "GPU" : "CPU");

                    std::vector<std::string> devices_to_load;
                    devices_to_load.push_back(prefill_device);
                    if (decode_device != prefill_device) {
                        devices_to_load.push_back(decode_device);
                    }
                    pool.load_on_devices(model_dir, devices_to_load);
                    pool.set_active_device(decode_device);

                    std::cout << "[Split] TTFT device: " << prefill_device
                              << ", Throughput device: " << decode_device
                              << ", Threshold: " << prefill_threshold_high
                              << " (low: " << prefill_threshold_low << ") tokens\n";
                } else if (server_mode) {
                    // In server mode, load only the primary device by default for faster startup.
                    // Use --preload-all-devices to load on all available devices for instant switching.
                    std::vector<std::string> devices_to_load;
                    if (preload_all_devices) {
                        // Load on all hardware devices (legacy behavior)
                        std::vector<std::string> all_hw;
                        for (const auto& d : scheduler.discover_devices()) {
                            if (d == "CPU" || d == "GPU" || d == "NPU") all_hw.push_back(d);
                        }
                        if (all_hw.empty()) all_hw.push_back(device);
                        devices_to_load = all_hw;
                        std::cout << "[Server Mode] Preloading on all devices (use --preload-all-devices=false for faster startup)\n";
                    } else {
                        // Load only on primary device (new default behavior)
                        devices_to_load = {device};
                        std::cout << "[Server Mode] Loading on primary device only (use --preload-all-devices for all devices)\n";
                    }
                    pool.load_on_devices(model_dir, devices_to_load);
                    pool.set_active_device(device);
                    std::cout << "[Server Mode] Loaded " << pool.get_loaded_devices().size()
                              << " device(s). Active: " << pool.get_active_device() << "\n" << std::flush;
                } else {
                    pool.load_on_devices(model_dir, {device});
                    pool.set_active_device(device);
                }
            }

            // SERVER MODE: Start REST API server instead of interactive loop
            if (server_mode) {
                std::cout << "\n[Server Mode] Starting OpenAI-compatible REST API server...\n";
                std::cout << "[Server Mode] Backend: " << pool.get_active_device() << "\n";
                if (context_routing) {
                    std::cout << "[Server Mode] Context-aware routing: ENABLED\n";
                }
                if (enable_kv_paging) {
                    std::cout << "[Server Mode] INT8 KV-cache optimization: ENABLED\n";
                }

                RuntimeConfig server_config;
                server_config.set_policy(policy);
                server_config.set_performance_profile(profile_for_policy(policy), "policy-selected");
                server_config.set_json_mode(json_mode);
                server_config.set_split_prefill(split_prefill);
                server_config.set_context_routing(context_routing);
                server_config.set_enable_kv_paging(enable_kv_paging);
                server_config.set_prefill_threshold_high(prefill_threshold_high);
                server_config.prefill_device = prefill_device;
                server_config.decode_device = decode_device;

                save_npu_launch_state(argc, argv);
                RestAPIServer api_server(&pool, &server_config, &kv_monitor, server_port);
                
                // Start server in a separate thread with exception handling
                std::thread server_thread([&api_server]() {
                    try {
                        api_server.start();
                    } catch (const std::exception& e) {
                        std::cerr << "[Thread] Server thread exception: " << e.what() << "\n";
                        std::cerr.flush();
                    } catch (...) {
                        std::cerr << "[Thread] Server thread unknown exception\n";
                        std::cerr.flush();
                    }
                });
                
                std::cout << "\n[Server Mode] Server running. Press Ctrl+C to stop.\n";
                std::cout << "[Server Mode] Test with: curl -X POST http://localhost:" << server_port << "/v1/chat/completions \\\n";
                std::cout << "  -H \"Content-Type: application/json\" \\\n";
                std::cout << "  -d '{\"model\":\"openvino\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'\n\n";
                std::cout.flush();
                
                // Wait for server thread
                server_thread.join();
                
                // Clean up and exit
                logline("=== SERVER MODE END ===");
                return 0;
            }

            std::cout << "READY. Type prompt ('help' for commands, 'exit' to quit)\n" << std::flush;
            logline("READY.");

            while (true) {
                std::cout << "\nYou: " << std::flush;
                std::string prompt;
                if (!std::getline(std::cin, prompt)) break;
                if (prompt == "exit") break;

                if (prompt == "help") {
                    print_help();
                    continue;
                }

                if (prompt == "memory") {
                    kv_monitor.print_memory_status();
                    continue;
                }

                if (prompt == "stats") {
                    if (!speculative_mode) {
                        pool.print_stats();
                    } else {
                        std::cout << "[Speculative] Stats unavailable in prototype.\n";
                    }
                    continue;
                }

                auto start_time = std::chrono::high_resolution_clock::now();
                std::string device_used = speculative_mode ? verify_device : pool.get_active_device();

                SpeculativeContext spec;
                BackendMetrics metrics;
                if (speculative_mode && spec_ready) {
                    SpeculativeRunResult spec_result = spec_engine.generate_stream(
                        prompt,
                        128,
                        draft_k,
                        min_accept,
                        spec_disable_on_low_accept
                    );

                    spec.requested = true;
                    spec.active = spec_result.active;
                    spec.draft_k = draft_k;
                    spec.draft_model = draft_model_dir;
                    spec.draft_device = draft_device;
                    spec.verify_device = verify_device;
                    spec.accept_rate = spec_result.proposed_tokens > 0 ? std::optional<double>(spec_result.accept_rate) : std::nullopt;
                    spec.accepted_tokens = spec_result.accepted_tokens;
                    spec.proposed_tokens = spec_result.proposed_tokens;
                    spec.disabled_reason = spec_result.disabled_reason;

                    metrics = spec_engine.get_last_metrics();
                } else {
                    if (split_prefill) {
                        int64_t prompt_tokens = estimate_prompt_tokens(prompt);
                        if (!use_prefill_device && prompt_tokens >= prefill_threshold_high) {
                            use_prefill_device = true;
                        } else if (use_prefill_device && prompt_tokens <= prefill_threshold_low) {
                            use_prefill_device = false;
                        }
                        std::string target_device = use_prefill_device ? prefill_device : decode_device;
                        if (pool.get_active_device() != target_device) {
                            pool.set_active_device(target_device);
                        }
                    }

                    device_used = pool.get_active_device();
                    pool.generate_stream(prompt);
                    metrics = pool.get_active_metrics();
                }
                
                auto end_time = std::chrono::high_resolution_clock::now();
                double elapsed = std::chrono::duration<double>(end_time - start_time).count();
                double total_ms = elapsed * 1000.0;
                
                if (!speculative_mode) {
                    std::cout << "\n[Time: " << elapsed << " seconds]\n" << std::flush;
                    logline("Generation time: " + std::to_string(elapsed) + " seconds");
                } else {
                    std::cout << "\n[Speculative Time: " << elapsed << " seconds]\n" << std::flush;
                }

                std::optional<std::string> error_message;
                bool fallback_used = false;
                emit_metrics_if_enabled(
                    json_mode,
                    std::cerr,
                    model_name,
                    device_used,
                    policy,
                    metrics,
                    total_ms,
                    fallback_used,
                    error_message,
                    spec
                );
                
                // Check memory status if optimization is enabled
                if (enable_kv_paging && kv_monitor.is_memory_critical(0.90f)) {
                    std::cout << "\n⚠️  [Memory Warning] RAM usage > 90% - Type 'memory' for details\n";
                }
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "\nOpenVINO GenAI exception: " << e.what() << "\n";
        logline(std::string("GenAI exception: ") + e.what());

        std::cout << "\nPress Enter to exit...\n";
        std::string dummy;
        std::getline(std::cin, dummy);
        return 1;
    } catch (...) {
        std::cerr << "\nUnknown exception caught!\n";
        logline("Unknown exception caught");
        return 1;
    }

    logline("=== RUN END ===");
    
    // Delete the log file when done
    try {
        std::filesystem::remove("runlog.txt");
    } catch (...) {
        // Silently ignore if deletion fails
    }
    
    return 0;
}