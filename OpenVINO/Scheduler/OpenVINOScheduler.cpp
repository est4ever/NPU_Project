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

    std::cout << "[Scheduler] Applying routing policy...\n";

    switch (policy) {
        case EnginePolicy::PERFORMANCE:
            // For max speed, force the heavy Arc GPU if it exists. 
            // If not, fallback to the fast CPU cores.
            std::cout << "[Scheduler] Policy: PERFORMANCE. Routing to GPU.\n";
            return has_gpu ? "GPU" : "CPU";

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
        
        double score = 0.0;
        
        switch (policy) {
            case EnginePolicy::PERFORMANCE:
                // Prioritize throughput
                score = bench.tokens_per_sec;
                break;
                
            case EnginePolicy::BATTERY_SAVER:
                // Prioritize NPU, then lowest TTFT
                if (device == "NPU") {
                    score = 1000000.0 + bench.tokens_per_sec;  // Huge bonus for NPU
                } else {
                    score = bench.tokens_per_sec * 0.5;  // Penalize non-NPU
                }
                break;
                
            case EnginePolicy::BALANCED:
            default:
                // Balance between TTFT and throughput
                score = bench.tokens_per_sec - (bench.ttft_ms * 0.1);
                break;
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