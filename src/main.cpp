#include <openvino/genai/llm_pipeline.hpp>
#include <openvino/runtime/core.hpp>
#include <iostream>
#include <vector>
#include <string>

static std::string pick_device() {
    try {
        ov::Core core;
        auto devs = core.get_available_devices();
        for (const auto& d : devs) {
            if (d.find("NPU") != std::string::npos) return "NPU";
        }
    } catch (...) {}
    return "CPU";
}

int main() {
    std::cout << "MAIN STARTED\n" << std::flush;

    // Use folder path (export output folder)
    std::string model_dir = "./models/TinyLlama_ov";

    std::string device = pick_device();
    std::cout << "Device chosen: " << device << "\n" << std::flush;
    std::cout << "Model dir: " << model_dir << "\n" << std::flush;

    try {
        ov::genai::LLMPipeline pipe(model_dir, device);

        ov::genai::GenerationConfig cfg;
        cfg.max_new_tokens = 128;
        cfg.temperature = 0.7f;

        std::cout << "READY. Type prompt (exit to quit)\n" << std::flush;

        while (true) {
            std::cout << "\nYou: " << std::flush;
            std::string prompt;
            if (!std::getline(std::cin, prompt)) break;
            if (prompt == "exit") break;

            std::cout << "AI: " << std::flush;
            auto streamer = [](const std::string& piece) {
                std::cout << piece << std::flush;
                return false;
            };

            pipe.generate(prompt, cfg, streamer);
            std::cout << "\n" << std::flush;
        }
    } catch (const std::exception& e) {
        std::cerr << "\nOpenVINO GenAI exception: " << e.what() << "\n";
        std::cerr << "(If device was NPU, retrying on CPU...)\n";

        if (device == "NPU") {
            try {
                ov::genai::LLMPipeline pipe(model_dir, "CPU");
                ov::genai::GenerationConfig cfg;
                cfg.max_new_tokens = 64;

                std::string prompt = "Say hello in one sentence.";
                auto streamer = [](const std::string& piece) {
                    std::cout << piece << std::flush;
                    return false;
                };

                std::cout << "AI: " << std::flush;
                pipe.generate(prompt, cfg, streamer);
                std::cout << "\n" << std::flush;
            } catch (const std::exception& e2) {
                std::cerr << "CPU retry failed: " << e2.what() << "\n";
            }
        }

        return 1;
    }

    return 0;
}