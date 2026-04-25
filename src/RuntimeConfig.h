#ifndef RUNTIMECONFIG_H
#define RUNTIMECONFIG_H

#include "../OpenVINO/Scheduler/IScheduler.h"
#include <string>
#include <atomic>
#include <mutex>

struct RuntimeConfig {
    std::atomic<bool> json_mode{false};
    std::atomic<bool> split_prefill{false};
    std::atomic<bool> context_routing{false};
    std::atomic<bool> enable_kv_paging{false};
    std::atomic<int> prefill_threshold_high{50};
    std::atomic<int> prefill_threshold_low{40};
    std::atomic<EnginePolicy> policy{EnginePolicy::BALANCED};
    
    std::string prefill_device = "NPU";
    std::string decode_device = "GPU";
    std::string performance_profile = "default";
    std::string performance_reason = "startup-default";
    mutable std::mutex profile_mutex;
    
    // Getters for atomic values
    bool get_json_mode() const { return json_mode.load(); }
    bool get_split_prefill() const { return split_prefill.load(); }
    bool get_context_routing() const { return context_routing.load(); }
    bool get_enable_kv_paging() const { return enable_kv_paging.load(); }
    int get_prefill_threshold_high() const { return prefill_threshold_high.load(); }
    int get_prefill_threshold_low() const { return prefill_threshold_low.load(); }
    EnginePolicy get_policy() const { return policy.load(); }
    
    // Setters for atomic values
    void set_json_mode(bool val) { json_mode.store(val); }
    void set_split_prefill(bool val) { split_prefill.store(val); }
    void set_context_routing(bool val) { context_routing.store(val); }
    void set_enable_kv_paging(bool val) { enable_kv_paging.store(val); }
    void set_prefill_threshold_high(int val) { prefill_threshold_high.store(val); }
    void set_prefill_threshold_low(int val) { prefill_threshold_low.store(val); }
    void set_policy(EnginePolicy val) { policy.store(val); }
    void set_performance_profile(const std::string& profile, const std::string& reason) {
        std::lock_guard<std::mutex> lock(profile_mutex);
        performance_profile = profile;
        performance_reason = reason;
    }
    std::string get_performance_profile() const {
        std::lock_guard<std::mutex> lock(profile_mutex);
        return performance_profile;
    }
    std::string get_performance_reason() const {
        std::lock_guard<std::mutex> lock(profile_mutex);
        return performance_reason;
    }
};

#endif // RUNTIMECONFIG_H
