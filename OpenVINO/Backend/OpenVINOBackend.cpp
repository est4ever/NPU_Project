#include "OpenVINOBackend.h"
#include <iostream>

void OpenVINOBackend::load_model(const std::string& model_path, const std::string& device) {
    std::cout << "[Backend] Loading model from: " << model_path << " to " << device << "...\n";
    
    ov::AnyMap pipeline_config;
    if (device == "NPU") {
        pipeline_config["CACHE_DIR"] = "./npu_cache";
        pipeline_config["GENERATE_HINT"] = "BEST_PERF";
    }

    pipe = std::make_unique<ov::genai::LLMPipeline>(model_path, device, pipeline_config);
    std::cout << "[Backend] Model loaded successfully.\n";
}

void OpenVINOBackend::generate_stream(const std::string& prompt) {
    if (!pipe) {
        std::cerr << "Error: Engine tried to generate, but no model is loaded.\n";
        return;
    }

    std::cout << "Assistant: ";

    ov::genai::GenerationConfig cfg;
    cfg.max_new_tokens = 128;
    cfg.temperature = 0.7f;

    std::string buffer;

    auto streamer = [&](const std::string& piece) {
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
            return true;
        }

        std::cout << piece << std::flush;
        return false;
    };

    auto result = pipe->generate(prompt, cfg, streamer);
    
    // Save the performance metrics for the stats command
    last_metrics = result.perf_metrics;
    std::cout << "\n";
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
        metrics.valid = true;
    }
    return metrics;
}