#include "SpeculativeEngine.h"
#include <openvino/genai/llm_pipeline.hpp>
#include <iostream>
#include <chrono>
#include <memory>

#if defined(__has_include)
#if __has_include(<openvino/genai/speculative_decoding/perf_metrics.hpp>)
#include <openvino/genai/speculative_decoding/perf_metrics.hpp>
#define ACOULM_OV_GENAI_SD_METRICS 1
#endif
#endif
#ifndef ACOULM_OV_GENAI_SD_METRICS
#define ACOULM_OV_GENAI_SD_METRICS 0
#endif

void SpeculativeEngine::load_models(
    const std::string& draft_model_path,
    const std::string& draft_device,
    const std::string& verify_model_path,
    const std::string& verify_device
) {
    draft_model_path_ = draft_model_path;
    draft_device_ = draft_device;
    verify_model_path_ = verify_model_path;
    verify_device_ = verify_device;
    loaded = true;
}

SpeculativeRunResult SpeculativeEngine::generate_stream(
    const std::string& prompt,
    int max_new_tokens,
    int draft_k,
    double min_accept,
    bool disable_on_low_accept
) {
    SpeculativeRunResult result;
    result.active = true;

    if (!loaded) {
        result.active = false;
        result.disabled_reason = "not_loaded";
        return result;
    }

    std::cout << "Assistant: " << std::flush;

    try {
        // Create the main/verify pipeline with integrated draft support
        // Using OpenVINO's native speculative decoding API
        ov::genai::LLMPipeline pipe(
            verify_model_path_,
            verify_device_,
            ov::genai::draft_model(draft_model_path_, draft_device_)
        );

        // Configure generation with speculative parameters
        ov::genai::GenerationConfig config;
        config.max_new_tokens = max_new_tokens;
        config.num_assistant_tokens = draft_k > 0 ? draft_k : 5;

        // Create a lambda-based streamer that returns StreamingStatus
        auto streamer = [](const std::string& token) {
            if (!token.empty()) {
                std::cout << token << std::flush;
            }
            return ov::genai::StreamingStatus::RUNNING;
        };

        // Generate with streaming and speculative decoding
        auto generation_result = pipe.generate(prompt, config, streamer);
        std::cout << "\n";

#if ACOULM_OV_GENAI_SD_METRICS
        // Extract speculative decoding metrics (OpenVINO GenAI 2026+)
        if (generation_result.extended_perf_metrics) {
            auto sd_metrics = std::dynamic_pointer_cast<ov::genai::SDPerModelsPerfMetrics>(
                generation_result.extended_perf_metrics
            );

            if (sd_metrics) {
                // Successfully obtained speculative metrics
                int64_t num_accepted = sd_metrics->get_num_accepted_tokens();
                int64_t num_draft_generated = sd_metrics->draft_model_metrics.get_num_generated_tokens();
                int64_t num_main_generated = sd_metrics->main_model_metrics.get_num_generated_tokens();

                result.generated_tokens = num_main_generated;
                result.proposed_tokens = num_draft_generated;
                result.accepted_tokens = num_accepted;
                result.accept_rate = num_draft_generated > 0
                    ? static_cast<double>(num_accepted) / static_cast<double>(num_draft_generated)
                    : 0.0;
                result.active = true;

                // Check auto-disable threshold
                if (disable_on_low_accept && num_draft_generated > 0 && result.accept_rate < min_accept) {
                    result.active = false;
                    result.disabled_reason = "low_accept_rate";
                }
            } else {
                // Extended metrics available but not speculative (fallback)
                result.active = false;
                result.disabled_reason = "metrics_cast_failed";
                result.generated_tokens = 0;
                result.proposed_tokens = 0;
                result.accepted_tokens = 0;
                result.accept_rate = 0.0;
            }
        } else {
            // No extended metrics (shouldn't happen with speculative pipeline)
            result.active = false;
            result.disabled_reason = "no_extended_metrics";
            result.generated_tokens = 0;
            result.proposed_tokens = 0;
            result.accepted_tokens = 0;
            result.accept_rate = 0.0;
        }
#else
        (void)generation_result;
        (void)disable_on_low_accept;
        (void)min_accept;
        // OpenVINO GenAI 2025.x: no speculative_decoding/perf_metrics.hpp — generation still ran above.
        result.active = true;
        result.disabled_reason = std::nullopt;
        result.generated_tokens = 0;
        result.proposed_tokens = 0;
        result.accepted_tokens = 0;
        result.accept_rate = 0.0;
#endif

        // Populate last_metrics for NDJSON emission
        last_metrics = BackendMetrics();
        last_metrics.generated_tokens = result.generated_tokens;
#if ACOULM_OV_GENAI_SD_METRICS
        last_metrics.generated_tokens_source = TokenCountSource::OpenVinoNative;
#else
        last_metrics.generated_tokens_source = TokenCountSource::Unknown;
#endif
        last_metrics.prompt_tokens = std::nullopt;
        last_metrics.prompt_tokens_source = TokenCountSource::Unknown;
        last_metrics.valid = true;

    } catch (const std::exception& e) {
        std::cerr << "[SpeculativeEngine] Error during generation: " << e.what() << std::endl;
        result.active = false;
        result.disabled_reason = "exception";
        result.generated_tokens = 0;
        result.proposed_tokens = 0;
        result.accepted_tokens = 0;
        result.accept_rate = 0.0;

        last_metrics = BackendMetrics();
        last_metrics.valid = false;
    }

    return result;
}
