#pragma once
#include "IBackend.h"
#include "OpenVINOBackend.h"
#include "../Scheduler/IScheduler.h"
#include <memory>
#include <map>
#include <string>

// Manages multiple backend instances (one per device)
class BackendPool {
private:
    std::map<std::string, std::unique_ptr<IBackend>> backends;
    std::string model_path;
    std::string current_device;

public:
    BackendPool() = default;

    // Load model on multiple devices
    void load_on_devices(const std::string& model_path, const std::vector<std::string>& devices);

    // Get backend for a specific device
    IBackend* get_backend(const std::string& device);

    // Generate using the current active device
    void generate_stream(const std::string& prompt);

    // Set which device to use for subsequent generations
    void set_active_device(const std::string& device);

    // Get current active device
    std::string get_active_device() const { return current_device; }
    
    // Get the active backend instance
    IBackend* get_active_backend() { return get_backend(current_device); }

    // Print stats from current device
    void print_stats();

    // Get all available backends
    std::vector<std::string> get_loaded_devices() const;
    
    // Get metrics from current active device
    BackendMetrics get_active_metrics() const;
    
    // Automatically select best device based on recent performance
    std::string auto_select_best_device(const std::map<std::string, DeviceBenchmark>& benchmarks);
};
