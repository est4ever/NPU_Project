#pragma once

#include <string>
#include <optional>
#include <cstdint>

enum class TokenCountSource {
    OpenVinoNative,
    Estimated,
    Unknown
};

struct BackendMetrics {
    double ttft_ms = 0.0;
    double tpot_ms = 0.0;
    double throughput = 0.0;
    std::optional<int64_t> prompt_tokens;
    std::optional<int64_t> generated_tokens;
    TokenCountSource prompt_tokens_source = TokenCountSource::Unknown;
    TokenCountSource generated_tokens_source = TokenCountSource::Unknown;
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
