#pragma once
#include <string>
#include <vector>
#include <map>

// These are the modes your users can choose from
enum class EnginePolicy {
    PERFORMANCE,   // Max speed (Favor GPU/CPU)
    BATTERY_SAVER, // Max efficiency (Favor NPU)
    BALANCED       // Let the engine decide (AUTO)
};

// Benchmark result for a single device
struct DeviceBenchmark {
    std::string device_name;
    double ttft_ms;        // Time to first token
    double tokens_per_sec; // Throughput
    bool success;          // Whether benchmark completed
};

class IScheduler {
public:
    virtual ~IScheduler() = default;

    // 1. Find the hardware
    virtual std::vector<std::string> discover_devices() = 0;

    // 2. Pick the best routing string based on the user's goal
    virtual std::string get_optimal_device(EnginePolicy policy) = 0;

    // 3. Run benchmarks on available devices
    virtual std::map<std::string, DeviceBenchmark> benchmark_devices(
        const std::string& model_path,
        const std::vector<std::string>& devices_to_test
    ) = 0;

    // 4. Get best device based on actual benchmarks
    virtual std::string get_best_device_from_benchmarks(
        const std::map<std::string, DeviceBenchmark>& benchmarks,
        EnginePolicy policy
    ) = 0;

    // 5. Context-aware routing: choose device based on prompt length
    virtual std::string get_device_for_context(
        size_t estimated_tokens,
        EnginePolicy policy
    ) = 0;

    // 6. Split-prefill routing: separate devices for prefill vs decode
    struct SplitPrefillDevices {
        std::string prefill_device;   // Best for TTFT (long prompts)
        std::string decode_device;    // Best for throughput (generation)
    };

    virtual SplitPrefillDevices get_split_prefill_devices(
        const std::map<std::string, DeviceBenchmark>& benchmarks
    ) = 0;
};