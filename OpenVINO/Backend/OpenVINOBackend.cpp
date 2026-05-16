#include "OpenVINOBackend.h"
#include "../../src/platform_util.h"
#include <iostream>
#include <type_traits>
#include <utility>
#include <vector>
#include <cstdlib>
#include <filesystem>
#include <openvino/genai/text_streamer.hpp>

namespace {
template <typename T, typename = void>
struct has_member_num_generated_tokens : std::false_type {};
template <typename T>
struct has_member_num_generated_tokens<T, std::void_t<decltype(std::declval<T>().num_generated_tokens)>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_num_input_tokens : std::false_type {};
template <typename T>
struct has_member_num_input_tokens<T, std::void_t<decltype(std::declval<T>().num_input_tokens)>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_prompt_tokens : std::false_type {};
template <typename T>
struct has_member_prompt_tokens<T, std::void_t<decltype(std::declval<T>().prompt_tokens)>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_input_tokens : std::false_type {};
template <typename T>
struct has_member_input_tokens<T, std::void_t<decltype(std::declval<T>().input_tokens)>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_generated_tokens_size : std::false_type {};
template <typename T>
struct has_member_generated_tokens_size<T, std::void_t<decltype(std::declval<T>().generated_tokens.size())>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_generated_ids_size : std::false_type {};
template <typename T>
struct has_member_generated_ids_size<T, std::void_t<decltype(std::declval<T>().generated_ids.size())>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_generated_ids : std::false_type {};
template <typename T>
struct has_member_generated_ids<T, std::void_t<decltype(std::declval<T>().generated_ids)>>
    : std::true_type {};

template <typename T, typename = void>
struct has_member_input_ids_size : std::false_type {};
template <typename T>
struct has_member_input_ids_size<T, std::void_t<decltype(std::declval<T>().input_ids.size())>>
    : std::true_type {};

template <typename T, typename = void>
struct has_method_get_num_generated_tokens : std::false_type {};
template <typename T>
struct has_method_get_num_generated_tokens<T, std::void_t<decltype(std::declval<T>().get_num_generated_tokens())>>
    : std::true_type {};

template <typename T, typename = void>
struct has_method_get_num_input_tokens : std::false_type {};
template <typename T>
struct has_method_get_num_input_tokens<T, std::void_t<decltype(std::declval<T>().get_num_input_tokens())>>
    : std::true_type {};

template <typename T>
std::optional<int64_t> extract_generated_tokens(const T& result) {
    if constexpr (has_member_num_generated_tokens<T>::value) {
        return static_cast<int64_t>(result.num_generated_tokens);
    } else if constexpr (has_method_get_num_generated_tokens<T>::value) {
        return static_cast<int64_t>(result.get_num_generated_tokens());
    } else if constexpr (has_member_generated_tokens_size<T>::value) {
        return static_cast<int64_t>(result.generated_tokens.size());
    } else if constexpr (has_member_generated_ids_size<T>::value) {
        return static_cast<int64_t>(result.generated_ids.size());
    }
    return std::nullopt;
}

template <typename T>
std::optional<int64_t> extract_prompt_tokens(const T& result) {
    if constexpr (has_member_num_input_tokens<T>::value) {
        return static_cast<int64_t>(result.num_input_tokens);
    } else if constexpr (has_method_get_num_input_tokens<T>::value) {
        return static_cast<int64_t>(result.get_num_input_tokens());
    } else if constexpr (has_member_prompt_tokens<T>::value) {
        return static_cast<int64_t>(result.prompt_tokens);
    } else if constexpr (has_member_input_tokens<T>::value) {
        return static_cast<int64_t>(result.input_tokens);
    } else if constexpr (has_member_input_ids_size<T>::value) {
        return static_cast<int64_t>(result.input_ids.size());
    }
    return std::nullopt;
}

template <typename Container, typename = void>
struct is_iterable : std::false_type {};
template <typename Container>
struct is_iterable<Container, std::void_t<decltype(std::declval<Container>().begin()),
                                         decltype(std::declval<Container>().end())>>
    : std::true_type {};

template <typename Container>
std::optional<std::vector<int64_t>> flatten_ids(const Container& ids) {
    if (ids.begin() == ids.end()) {
        return std::vector<int64_t>{};
    }

    using Elem = std::decay_t<decltype(*ids.begin())>;
    if constexpr (std::is_integral_v<Elem>) {
        return std::vector<int64_t>(ids.begin(), ids.end());
    } else if constexpr (is_iterable<Elem>::value) {
        auto first = ids.begin();
        return std::vector<int64_t>(first->begin(), first->end());
    }

    return std::nullopt;
}

template <typename T>
std::optional<std::vector<int64_t>> extract_generated_ids(const T& result) {
    if constexpr (has_member_generated_ids<T>::value) {
        return flatten_ids(result.generated_ids);
    }
    return std::nullopt;
}

std::string sanitize_cache_token(std::string token) {
    for (char& c : token) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) {
            c = '_';
        }
    }
    if (token.empty()) {
        token = "model";
    }
    return token;
}

std::string resolve_cache_dir(const std::string& device, const std::string& model_path) {
    const char* home = std::getenv("ACOULM_HOME");
    std::filesystem::path base = home && home[0] ? std::filesystem::path(home) : std::filesystem::current_path();
    const std::string root = device == "NPU" ? "npu_cache" : "gpu_cache";
    std::string leaf = sanitize_cache_token(std::filesystem::path(model_path).stem().string());
    std::filesystem::path dir = base / root / leaf;
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    const std::string path = dir.string();
    if (root == "gpu_cache") {
        acoulm::set_env_var("OV_CACHE_DIR", path);
    }
    return path;
}

bool fast_load_enabled() {
    const char* v = std::getenv("ACOULM_FAST_LOAD");
    return v && v[0] == '1';
}

ov::AnyMap build_pipeline_config(const std::string& device, bool minimal_cpu, const std::string& model_path) {
    ov::AnyMap pipeline_config;

    const bool fast_load = fast_load_enabled();
    if (!minimal_cpu && !fast_load) {
        pipeline_config["KV_CACHE_PRECISION"] = "u8";
        pipeline_config["DYNAMIC_QUANTIZATION_GROUP_SIZE"] = 32;
    }

    if (device == "NPU") {
        pipeline_config["CACHE_DIR"] = resolve_cache_dir(device, model_path);
        pipeline_config["GENERATE_HINT"] = "BEST_PERF";
        pipeline_config["NPU_USE_NPUW"] = true;
    } else if (device == "GPU") {
        pipeline_config["GPU_ENABLE_SDPA_OPTIMIZATION"] = true;
        pipeline_config["CACHE_DIR"] = resolve_cache_dir(device, model_path);
        pipeline_config["NUM_STREAMS"] = 1;
    } else if (device == "CPU") {
        pipeline_config["NUM_STREAMS"] = 1;
    }

    const char* perfMode = std::getenv("ACOULM_PERF_MODE");
    const std::string perfModeStr = perfMode ? perfMode : "";
    if (perfModeStr == "balanced-performance") {
        pipeline_config["PERFORMANCE_HINT"] = "THROUGHPUT";
    } else {
        pipeline_config["PERFORMANCE_HINT"] = "LATENCY";
    }

    return pipeline_config;
}

} // namespace

void OpenVINOBackend::load_model(const std::string& model_path, const std::string& device) {
    std::cout << "[Backend] Loading model from: " << model_path << " to " << device << "...\n";
    if (device == "GPU" || device == "NPU") {
        std::cout << "[Backend] Compile cache: " << resolve_cache_dir(device, model_path) << "\n";
    }
    if (fast_load_enabled()) {
        std::cout << "[Backend] ACOULM_FAST_LOAD=1 (skipping extra KV quant for faster first compile)\n";
    }

    const auto attempt_load = [&](const ov::AnyMap& pipeline_config, const char* label) {
        std::cout << "[Backend] Load attempt (" << label << ") on " << device << "\n";
        pipe = std::make_unique<ov::genai::LLMPipeline>(model_path, device, pipeline_config);
    };

    std::exception_ptr first_error;
    try {
        if (device == "CPU") {
            std::cout << "[Backend] CPU: using minimal plugin config first (best compatibility).\n";
            attempt_load(build_pipeline_config(device, true, model_path), "cpu-minimal");
        } else {
            if (!fast_load_enabled()) {
                std::cout << "[Backend] Enabling INT8 KV-cache quantization for memory efficiency...\n";
            }
            attempt_load(build_pipeline_config(device, false, model_path), "default");
        }
        std::cout << "[Backend] Model loaded successfully on " << device << ".\n";
        return;
    } catch (...) {
        first_error = std::current_exception();
    }

    if (device == "CPU") {
        try {
            std::cout << "[Backend] CPU minimal load failed; retrying with full KV-cache config...\n";
            attempt_load(build_pipeline_config(device, false, model_path), "cpu-full");
            std::cout << "[Backend] Model loaded successfully on CPU (full config).\n";
            return;
        } catch (const std::exception& retry_e) {
            std::cerr << "[Backend] CPU full-config retry failed: " << retry_e.what() << "\n";
        } catch (...) {
            std::cerr << "[Backend] CPU full-config retry failed with unknown error.\n";
        }
    }

    if (first_error) {
        std::rethrow_exception(first_error);
    }
}

void OpenVINOBackend::generate_stream(const std::string& prompt) {
    if (!pipe) {
        std::cerr << "Error: Engine tried to generate, but no model is loaded.\n";
        return;
    }

    std::lock_guard<std::mutex> lock(inference_mutex_);

    std::cout << "Assistant: ";

    ov::genai::GenerationConfig cfg;
    cfg.max_new_tokens = 128;
    cfg.temperature = 0.7f;

    std::string buffer;

    auto callback = [&](std::string piece) -> ov::genai::StreamingStatus {
        buffer += piece;

        const char* markers[] = {"\nYou:", "\nUser:", "\nAI:"};
        size_t cut = std::string::npos;
        for (const char* m : markers) {
            size_t pos = buffer.find(m);
            if (pos != std::string::npos) {
                cut = pos;
                break;
            }
        }

        if (cut != std::string::npos) {
            std::cout << buffer.substr(0, cut) << std::flush;
            return ov::genai::StreamingStatus::STOP;
        }

        std::cout << piece << std::flush;
        return ov::genai::StreamingStatus::RUNNING;
    };

    auto tokenizer = pipe->get_tokenizer();
    auto streamer = std::make_shared<ov::genai::TextStreamer>(tokenizer, callback);
    auto result = pipe->generate(prompt, cfg, streamer);
    
    // Save the performance metrics for the stats command
    last_metrics = result.perf_metrics;
    last_prompt_tokens = extract_prompt_tokens(result);
    last_generated_tokens = extract_generated_tokens(result);
    last_prompt_tokens_source = last_prompt_tokens.has_value() ? TokenCountSource::OpenVinoNative
                                                               : TokenCountSource::Unknown;
    last_generated_tokens_source = last_generated_tokens.has_value() ? TokenCountSource::OpenVinoNative
                                                                     : TokenCountSource::Unknown;
    std::cout << "\n";
}

GeneratedOutput OpenVINOBackend::generate_output(
    const std::string& prompt,
    int max_new_tokens,
    float temperature,
    bool stream_to_stdout
) {
    GeneratedOutput output;
    if (!pipe) {
        std::cerr << "Error: Engine tried to generate, but no model is loaded.\n";
        return output;
    }

    std::lock_guard<std::mutex> lock(inference_mutex_);

    ov::genai::GenerationConfig cfg;
    cfg.max_new_tokens = max_new_tokens;
    cfg.temperature = temperature;

    std::string buffer;
    auto callback = [&](std::string piece) -> ov::genai::StreamingStatus {
        buffer += piece;
        if (stream_to_stdout) {
            std::cout << piece << std::flush;
        }
        return ov::genai::StreamingStatus::RUNNING;
    };

    auto tokenizer = pipe->get_tokenizer();
    auto streamer = std::make_shared<ov::genai::TextStreamer>(tokenizer, callback);
    auto result = pipe->generate(prompt, cfg, streamer);
    output.text = buffer;

    last_metrics = result.perf_metrics;   // keep get_last_metrics() current
    output.metrics.ttft_ms = result.perf_metrics.get_ttft().mean;
    output.metrics.tpot_ms = result.perf_metrics.get_tpot().mean;
    output.metrics.throughput = result.perf_metrics.get_throughput().mean;
    output.metrics.valid = true;

    auto ids = extract_generated_ids(result);
    if (ids.has_value()) {
        output.token_ids = std::move(ids.value());
        output.token_ids_valid = true;
    }

    return output;
}

void OpenVINOBackend::print_stats() {
    std::cout << "\n--- Hardware Performance Stats ---\n";
    // OpenVINO GenAI natively tracks these critical metrics
    std::cout << "Time To First Token (TTFT): " << last_metrics.get_ttft().mean << " ms\n";
    std::cout << "Time Per Output Token (TPOT): " << last_metrics.get_tpot().mean << " ms/token\n";
    std::cout << "Throughput: " << last_metrics.get_throughput().mean << " tokens/s\n";
    std::cout << "----------------------------------\n";
}

BackendMetrics OpenVINOBackend::get_last_metrics() const {
    BackendMetrics metrics;
    if (pipe) {
        metrics.ttft_ms = last_metrics.get_ttft().mean;
        metrics.tpot_ms = last_metrics.get_tpot().mean;
        metrics.throughput = last_metrics.get_throughput().mean;
        metrics.prompt_tokens = last_prompt_tokens;
        metrics.generated_tokens = last_generated_tokens;
        metrics.prompt_tokens_source = last_prompt_tokens_source;
        metrics.generated_tokens_source = last_generated_tokens_source;
        metrics.valid = true;
    }
    return metrics;
}