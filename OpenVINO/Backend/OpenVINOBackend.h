#pragma once
#include "IBackend.h"
#include <openvino/genai/llm_pipeline.hpp>
#include <memory>

class OpenVINOBackend : public IBackend {
private:
    // We keep the LLMPipeline hidden inside this specific backend
    std::unique_ptr<ov::genai::LLMPipeline> pipe;
    mutable ov::genai::PerfMetrics last_metrics;

public:
    OpenVINOBackend() = default;
    ~OpenVINOBackend() override = default;

    // We must provide the actual code for these rules
    void load_model(const std::string& model_path, const std::string& device) override;
    void generate_stream(const std::string& prompt) override;
    void print_stats() override;
    BackendMetrics get_last_metrics() const override;
};