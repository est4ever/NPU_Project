#pragma once
#include "IBackend.h"
#include <openvino/genai/llm_pipeline.hpp>
#include <memory>
#include <vector>

struct GeneratedOutput {
    std::vector<int64_t> token_ids;
    std::string text;
    BackendMetrics metrics;
    bool token_ids_valid = false;
};

class OpenVINOBackend : public IBackend {
private:
    // We keep the LLMPipeline hidden inside this specific backend
    std::unique_ptr<ov::genai::LLMPipeline> pipe;
    mutable ov::genai::PerfMetrics last_metrics;
    std::optional<int64_t> last_prompt_tokens;
    std::optional<int64_t> last_generated_tokens;
    TokenCountSource last_prompt_tokens_source = TokenCountSource::Unknown;
    TokenCountSource last_generated_tokens_source = TokenCountSource::Unknown;

public:
    OpenVINOBackend() = default;
    ~OpenVINOBackend() override = default;

    // We must provide the actual code for these rules
    void load_model(const std::string& model_path, const std::string& device) override;
    void generate_stream(const std::string& prompt) override;
    void print_stats() override;
    BackendMetrics get_last_metrics() const override;

    GeneratedOutput generate_output(
        const std::string& prompt,
        int max_new_tokens,
        float temperature,
        bool stream_to_stdout
    );
};