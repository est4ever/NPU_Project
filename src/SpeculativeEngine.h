#pragma once

#include "../OpenVINO/Backend/OpenVINOBackend.h"
#include <cstdint>
#include <optional>
#include <string>

struct SpeculativeRunResult {
    bool active = false;
    std::optional<std::string> disabled_reason;
    int64_t proposed_tokens = 0;
    int64_t accepted_tokens = 0;
    double accept_rate = 0.0;
    int64_t generated_tokens = 0;
};

class SpeculativeEngine {
public:
    void load_models(
        const std::string& draft_model_path,
        const std::string& draft_device,
        const std::string& verify_model_path,
        const std::string& verify_device
    );

    SpeculativeRunResult generate_stream(
        const std::string& prompt,
        int max_new_tokens,
        int draft_k,
        double min_accept,
        bool disable_on_low_accept
    );

    BackendMetrics get_last_metrics() const { return last_metrics; }

private:
    std::string draft_model_path_;
    std::string draft_device_;
    std::string verify_model_path_;
    std::string verify_device_;
    BackendMetrics last_metrics;
    bool loaded = false;
};
