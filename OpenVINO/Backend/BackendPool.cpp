#include "BackendPool.h"
#include <iostream>
#include <stdexcept>

void BackendPool::load_on_devices(const std::string& model_path_arg, const std::vector<std::string>& devices) {
    model_path = model_path_arg;
    backends.clear();
    current_device.clear();
    
    std::cout << "\n[BackendPool] Loading model on " << devices.size() << " device(s)...\n";
    
    for (const auto& device : devices) {
        try {
            auto backend = std::make_unique<OpenVINOBackend>();
            backend->load_model(model_path, device);
            backends[device] = std::move(backend);
            
            if (current_device.empty()) {
                current_device = device; // Set first device as default
            }
        } catch (const std::exception& e) {
            std::cerr << "[BackendPool] Failed to load on " << device << ": " << e.what() << "\n";
        }
    }
    
    if (backends.empty()) {
        throw std::runtime_error("[BackendPool] Failed to load model on all requested devices.");
    }

    std::cout << "[BackendPool] Successfully loaded on " << backends.size() << " device(s)\n";
}

IBackend* BackendPool::get_backend(const std::string& device) {
    auto it = backends.find(device);
    if (it != backends.end()) {
        return it->second.get();
    }
    return nullptr;
}

void BackendPool::generate_stream(const std::string& prompt) {
    auto* backend = get_backend(current_device);
    if (backend) {
        backend->generate_stream(prompt);
    } else {
        std::cerr << "[BackendPool] Error: No backend loaded for device " << current_device << "\n";
    }
}

void BackendPool::set_active_device(const std::string& device) {
    if (backends.find(device) != backends.end()) {
        current_device = device;
        std::cout << "[BackendPool] Switched to device: " << device << "\n";
    } else {
        std::cerr << "[BackendPool] Error: Device " << device << " not loaded\n";
    }
}

void BackendPool::print_stats() {
    auto* backend = get_backend(current_device);
    if (backend) {
        std::cout << "[Device: " << current_device << "]\n";
        backend->print_stats();
    } else {
        std::cerr << "[BackendPool] Error: No backend loaded for device " << current_device << "\n";
    }
}

std::vector<std::string> BackendPool::get_loaded_devices() const {
    std::vector<std::string> devices;
    for (const auto& pair : backends) {
        devices.push_back(pair.first);
    }
    return devices;
}

BackendMetrics BackendPool::get_active_metrics() const {
    auto* backend = const_cast<BackendPool*>(this)->get_backend(current_device);
    if (backend) {
        return backend->get_last_metrics();
    }
    return BackendMetrics();
}

std::string BackendPool::auto_select_best_device(const std::map<std::string, DeviceBenchmark>& benchmarks) {
    // Get current device's actual performance
    auto current_metrics = get_active_metrics();
    
    if (!current_metrics.valid) {
        return current_device; // No data yet, stay on current
    }
    
    // Check if current device is underperforming compared to its benchmark
    auto bench_it = benchmarks.find(current_device);
    if (bench_it == benchmarks.end()) {
        return current_device;
    }
    
    const auto& current_bench = bench_it->second;
    
    // If TTFT is more than 50% worse than benchmark, or throughput dropped by 30%
    bool underperforming = false;
    if (current_metrics.ttft_ms > current_bench.ttft_ms * 1.5) {
        underperforming = true;
        std::cout << "[Auto-Switch] TTFT degraded: " << current_metrics.ttft_ms 
                  << " ms vs benchmark " << current_bench.ttft_ms << " ms\n";
    }
    if (current_metrics.throughput < current_bench.tokens_per_sec * 0.7) {
        underperforming = true;
        std::cout << "[Auto-Switch] Throughput degraded: " << current_metrics.throughput 
                  << " tok/s vs benchmark " << current_bench.tokens_per_sec << " tok/s\n";
    }
    
    if (!underperforming) {
        return current_device; // Performance is acceptable
    }
    
    // Find best alternative device
    std::string best_device = current_device;
    double best_score = current_metrics.throughput;
    
    for (const auto& [device, bench] : benchmarks) {
        if (device == current_device) continue;
        if (backends.find(device) == backends.end()) continue;
        if (!bench.success) continue;
        
        double score = bench.tokens_per_sec;
        if (score > best_score * 1.2) { // Must be at least 20% better
            best_score = score;
            best_device = device;
        }
    }
    
    if (best_device != current_device) {
        std::cout << "[Auto-Switch] Switching from " << current_device 
                  << " to " << best_device << " (expected +" 
                  << ((best_score / current_metrics.throughput - 1.0) * 100.0) 
                  << "% throughput)\n";
    }
    
    return best_device;
}
