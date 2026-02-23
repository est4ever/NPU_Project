#pragma once

#include <string>

struct BackendMetrics {
    double ttft_ms = 0.0;
    double tpot_ms = 0.0;
    double throughput = 0.0;
    bool valid = false;
};

class IBackend {
public:
    virtual ~IBackend() = default;

    virtual void load_model(const std::string& model_path, const std::string& device) = 0;
    virtual void generate_stream(const std::string& prompt) = 0;
    virtual void print_stats() = 0;
    virtual BackendMetrics get_last_metrics() const = 0;
};
