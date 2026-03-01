#pragma once
#include "IScheduler.h"
#include <openvino/openvino.hpp>

class OpenVINOScheduler : public IScheduler {
private:
    ov::Core core; // OpenVINO's hardware manager
    std::vector<std::string> available_devices;

public:
    OpenVINOScheduler();

    std::vector<std::string> discover_devices() override;
    std::string get_optimal_device(EnginePolicy policy) override;
    
    std::map<std::string, DeviceBenchmark> benchmark_devices(
        const std::string& model_path,
        const std::vector<std::string>& devices_to_test
    ) override;

    std::map<std::string, double> benchmark_ttft_for_prompt(
        const std::string& model_path,
        const std::vector<std::string>& devices_to_test,
        const std::string& prompt,
        int max_new_tokens = 1
    );
    
    std::string get_best_device_from_benchmarks(
        const std::map<std::string, DeviceBenchmark>& benchmarks,
        EnginePolicy policy
    ) override;

    std::string get_device_for_context(
        size_t estimated_tokens,
        EnginePolicy policy
    ) override;

    SplitPrefillDevices get_split_prefill_devices(
        const std::map<std::string, DeviceBenchmark>& benchmarks
    ) override;

    // Helper: Estimate token count from string (rough approximation)
    static size_t estimate_token_count(const std::string& text);
};