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

// Helper functions for EnginePolicy
inline std::string policy_to_string(EnginePolicy p) {
    switch (p) {
        case EnginePolicy::PERFORMANCE: return "PERFORMANCE";
        case EnginePolicy::BATTERY_SAVER: return "BATTERY_SAVER";
        case EnginePolicy::BALANCED: return "BALANCED";
        default: return "UNKNOWN";
    }
}

inline EnginePolicy string_to_policy(const std::string& str) {
    if (str == "PERFORMANCE") return EnginePolicy::PERFORMANCE;
    if (str == "BATTERY_SAVER") return EnginePolicy::BATTERY_SAVER;
    if (str == "BALANCED") return EnginePolicy::BALANCED;
    return EnginePolicy::BALANCED; // default
}

// Benchmark result for a single device
struct DeviceBenchmark {
    std::string device_name;
    double ttft_ms;        // Time to first token
    double tokens_per_sec; // Throughput
    bool success;          // Whether benchmark completed
};

inline double score_benchmark_for_policy(const DeviceBenchmark& bench, EnginePolicy policy) {
    if (!bench.success) {
        return -1e12;
    }
    const double ttft_penalty = bench.ttft_ms > 0.0 ? bench.ttft_ms : 5000.0;
    const double throughput = bench.tokens_per_sec > 0.0 ? bench.tokens_per_sec : 0.0;
    switch (policy) {
        case EnginePolicy::PERFORMANCE:
            // Balanced PERFORMANCE target: prioritize throughput while still penalizing poor TTFT.
            return (throughput * 0.75) - (ttft_penalty * 0.25);
        case EnginePolicy::BATTERY_SAVER:
            return throughput * 0.35 - ttft_penalty * 0.65;
        case EnginePolicy::BALANCED:
        default:
            return throughput * 0.55 - ttft_penalty * 0.45;
    }
}

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