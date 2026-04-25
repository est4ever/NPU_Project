#include "OpenVINOScheduler.h"
#include <openvino/genai/llm_pipeline.hpp>
#include <iostream>
#include <algorithm>
#include <chrono>

OpenVINOScheduler::OpenVINOScheduler() {
    // Automatically discover devices when the scheduler boots up
    discover_devices();
}

std::vector<std::string> OpenVINOScheduler::discover_devices() {
    available_devices = core.get_available_devices();
    
    std::cout << "\n[Scheduler] Hardware Discovered:\n";
    for (const auto& device : available_devices) {
        // Query the actual name of the chip (e.g., "Intel(R) Arc(TM) 140V")
        std::string name = core.get_property(device, ov::device::full_name);
        std::cout << "  - " << device << " : " << name << "\n";
    }
    return available_devices;
}

std::string OpenVINOScheduler::get_optimal_device(EnginePolicy policy) {
    bool has_gpu = std::find(available_devices.begin(), available_devices.end(), "GPU") != available_devices.end();
    bool has_npu = std::find(available_devices.begin(), available_devices.end(), "NPU") != available_devices.end();
    bool has_cpu = std::find(available_devices.begin(), available_devices.end(), "CPU") != available_devices.end();

    std::cout << "[Scheduler] Applying routing policy...\n";

    switch (policy) {
        case EnginePolicy::PERFORMANCE:
            // PERFORMANCE is now balanced TTFT + throughput (not hard GPU-only).
            if (has_gpu && has_npu) {
                std::cout << "[Scheduler] Policy: PERFORMANCE. Using AUTO:GPU,NPU,CPU for balanced speed.\n";
                return "AUTO:GPU,NPU,CPU";
            }
            if (has_gpu) {
                std::cout << "[Scheduler] Policy: PERFORMANCE. Routing to GPU.\n";
                return "GPU";
            }
            if (has_npu) {
                std::cout << "[Scheduler] Policy: PERFORMANCE. Routing to NPU (GPU unavailable).\n";
                return "NPU";
            }
            return has_cpu ? "CPU" : "AUTO:CPU";

        case EnginePolicy::BATTERY_SAVER:
            // For saving battery, we absolutely want the NPU.
            std::cout << "[Scheduler] Policy: BATTERY SAVER. Routing to NPU.\n";
            return has_npu ? "NPU" : "CPU";

        case EnginePolicy::BALANCED:
        default:
            // Heterogeneous routing: Tell OpenVINO to use the GPU for heavy 
            // prompt reading, but fallback to NPU/CPU for easy tasks.
            std::cout << "[Scheduler] Policy: BALANCED. Using AUTO Heterogeneous Routing.\n";
            return "AUTO:GPU,NPU,CPU"; 
    }
}

std::map<std::string, DeviceBenchmark> OpenVINOScheduler::benchmark_devices(
    const std::string& model_path,
    const std::vector<std::string>& devices_to_test
) {
    std::map<std::string, DeviceBenchmark> results;
    
    std::cout << "\n[Scheduler] Starting device benchmarks (2 sec per device)...\n";
    
    const std::string test_prompt = "Explain quantum computing in one sentence.";
    
    for (const auto& device : devices_to_test) {
        DeviceBenchmark benchmark;
        benchmark.device_name = device;
        benchmark.success = false;
        
        std::cout << "[Scheduler] Testing " << device << "... " << std::flush;
        
        try {
            // Configure pipeline for this device
            ov::AnyMap pipeline_config;
            if (device == "NPU") {
                pipeline_config["CACHE_DIR"] = "./npu_cache";
                pipeline_config["GENERATE_HINT"] = "BEST_PERF";
            }
            
            // Load model on this device
            auto start_load = std::chrono::high_resolution_clock::now();
            ov::genai::LLMPipeline pipe(model_path, device, pipeline_config);
            auto end_load = std::chrono::high_resolution_clock::now();
            double load_time = std::chrono::duration<double>(end_load - start_load).count();
            
            // Configure generation
            ov::genai::GenerationConfig cfg;
            cfg.max_new_tokens = 32;  // Short test
            cfg.temperature = 0.7f;
            
            // Run benchmark generation
            auto start_gen = std::chrono::high_resolution_clock::now();
            auto result = pipe.generate(test_prompt, cfg);
            auto end_gen = std::chrono::high_resolution_clock::now();
            
            // Extract metrics
            auto perf = result.perf_metrics;
            benchmark.ttft_ms = perf.get_ttft().mean;
            benchmark.tokens_per_sec = perf.get_throughput().mean;
            benchmark.success = true;
            
            std::cout << "✓ TTFT: " << benchmark.ttft_ms << " ms, " 
                      << "Throughput: " << benchmark.tokens_per_sec << " tok/s\n";
            
        } catch (const std::exception& e) {
            std::cout << "✗ Failed: " << e.what() << "\n";
            benchmark.ttft_ms = 999999.0;  // Very high penalty
            benchmark.tokens_per_sec = 0.0;
        }
        
        results[device] = benchmark;
    }
    
    std::cout << "[Scheduler] Benchmarking complete.\n\n";
    return results;
}

std::map<std::string, double> OpenVINOScheduler::benchmark_ttft_for_prompt(
    const std::string& model_path,
    const std::vector<std::string>& devices_to_test,
    const std::string& prompt,
    int max_new_tokens
) {
    std::map<std::string, double> results;

    std::cout << "[Scheduler] Measuring TTFT for prompt length " << prompt.size() << " chars...\n";

    for (const auto& device : devices_to_test) {
        std::cout << "[Scheduler] TTFT test on " << device << "... " << std::flush;
        try {
            ov::AnyMap pipeline_config;
            if (device == "NPU") {
                pipeline_config["CACHE_DIR"] = "./npu_cache";
                pipeline_config["GENERATE_HINT"] = "BEST_PERF";
            }

            ov::genai::LLMPipeline pipe(model_path, device, pipeline_config);

            ov::genai::GenerationConfig cfg;
            cfg.max_new_tokens = max_new_tokens;
            cfg.temperature = 0.0f;

            auto result = pipe.generate(prompt, cfg);
            auto perf = result.perf_metrics;
            double ttft = perf.get_ttft().mean;
            results[device] = ttft;
            std::cout << "TTFT: " << ttft << " ms\n";
        } catch (const std::exception& e) {
            std::cout << "Failed: " << e.what() << "\n";
            results[device] = 999999.0;
        }
    }

    return results;
}

std::string OpenVINOScheduler::get_best_device_from_benchmarks(
    const std::map<std::string, DeviceBenchmark>& benchmarks,
    EnginePolicy policy
) {
    if (benchmarks.empty()) {
        return "CPU";  // Fallback
    }
    
    std::cout << "[Scheduler] Selecting best device based on benchmarks and policy...\n";
    
    std::string best_device = "CPU";
    double best_score = -1.0;
    
    for (const auto& [device, bench] : benchmarks) {
        if (!bench.success) continue;
        
        double score = score_benchmark_for_policy(bench, policy);
        if (policy == EnginePolicy::BATTERY_SAVER && device == "NPU") {
            score += 10000.0;
        }
        
        std::cout << "  - " << device << ": score = " << score << "\n";
        
        if (score > best_score) {
            best_score = score;
            best_device = device;
        }
    }
    
    std::cout << "[Scheduler] Selected: " << best_device << " (score: " << best_score << ")\n";
    return best_device;
}
// Context-aware routing based on prompt length
std::string OpenVINOScheduler::get_device_for_context(
    size_t estimated_tokens,
    EnginePolicy policy
) {
    // Thresholds for routing decisions
    const size_t SHORT_PROMPT = 100;
    const size_t MEDIUM_PROMPT = 500;
    const size_t LONG_PROMPT = 2000;
    
    bool has_gpu = std::find(available_devices.begin(), available_devices.end(), "GPU") != available_devices.end();
    bool has_npu = std::find(available_devices.begin(), available_devices.end(), "NPU") != available_devices.end();
    
    std::cout << "[Scheduler] Context-aware routing for ~" << estimated_tokens << " tokens...\n";
    
    if (estimated_tokens < SHORT_PROMPT) {
        std::cout << "[Scheduler] Short context: routing to NPU/CPU for fast decode\n";
        return has_npu ? "NPU" : "CPU";
    } else if (estimated_tokens < MEDIUM_PROMPT) {
        std::cout << "[Scheduler] Medium context: using standard policy\n";
        return get_optimal_device(policy);
    } else if (estimated_tokens < LONG_PROMPT) {
        std::cout << "[Scheduler] Long context: routing to GPU for prefill\n";
        return has_gpu ? "GPU" : "CPU";
    } else {
        std::cout << "[Scheduler] Very long context: forcing GPU for heavy prefill\n";
        return has_gpu ? "GPU" : "CPU";
    }
}

IScheduler::SplitPrefillDevices OpenVINOScheduler::get_split_prefill_devices(
    const std::map<std::string, DeviceBenchmark>& benchmarks
) {
    SplitPrefillDevices result;
    std::string best_prefill = "CPU";
    double best_ttft = 999999.0;
    std::string best_decode = "CPU";
    double best_throughput = 0.0;
    
    for (const auto& [device, bench] : benchmarks) {
        if (!bench.success) continue;
        if (bench.ttft_ms < best_ttft) {
            best_ttft = bench.ttft_ms;
            best_prefill = device;
        }
        if (bench.tokens_per_sec > best_throughput) {
            best_throughput = bench.tokens_per_sec;
            best_decode = device;
        }
    }
    
    result.prefill_device = best_prefill;
    result.decode_device = best_decode;
    
    std::cout << "[Scheduler] Split-prefill strategy:\n";
    std::cout << "  - Prefill (TTFT): " << best_prefill << " (" << best_ttft << " ms)\n";
    std::cout << "  - Decode (throughput): " << best_decode << " (" << best_throughput << " tok/s)\n";
    
    return result;
}

size_t OpenVINOScheduler::estimate_token_count(const std::string& text) {
    return text.length() / 4;
}
