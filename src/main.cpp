#include <openvino/genai/llm_pipeline.hpp>
#include <openvino/runtime/core.hpp>

#include <windows.h>
#include <iostream>
#include <vector>
#include <string>
#include <fstream>

static void logline(const std::string& s) {
    std::ofstream f("runlog.txt", std::ios::app);
    f << s << std::endl;
}

static std::string pick_device_and_print() {
    std::string chosen = "CPU";
    try {
        ov::Core core;
        auto devs = core.get_available_devices();

        std::cout << "Available devices:\n";
        logline("Available devices:");
        for (const auto& d : devs) {
            std::cout << "  - " << d << "\n";
            logline("  - " + d);
            if (d.find("NPU") != std::string::npos) chosen = "NPU";
        }
    } catch (const std::exception& e) {
        std::cerr << "Device scan failed: " << e.what() << "\n";
        logline(std::string("Device scan failed: ") + e.what());
        chosen = "CPU";
    } catch (...) {
        std::cerr << "Device scan failed: unknown\n";
        logline("Device scan failed: unknown");
        chosen = "CPU";
    }
    return chosen;
}

int main() {
    // Show EXE path (proves which binary is running)
    char exePath[MAX_PATH];
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);
    MessageBoxA(nullptr, exePath, "EXE PATH", MB_OK);

    logline("=== RUN START ===");
    logline(std::string("EXE: ") + exePath);

    std::cout << "MAIN STARTED\n" << std::flush;
    logline("MAIN STARTED");

    // Export output folder
    std::string model_dir = "./models/TinyLlama_ov";
    std::cout << "Model dir: " << model_dir << "\n" << std::flush;
    logline("Model dir: " + model_dir);

    std::string device = pick_device_and_print();
    std::cout << "Device chosen: " << device << "\n" << std::flush;
    logline("Device chosen: " + device);

    try {
        ov::genai::LLMPipeline pipe(model_dir, device);

        ov::genai::GenerationConfig cfg;
        cfg.max_new_tokens = 128;
        cfg.temperature = 0.7f;

        std::cout << "READY. Type prompt (exit to quit)\n" << std::flush;
        logline("READY.");

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
        logline(std::string("GenAI exception: ") + e.what());

        if (device == "NPU") {
            std::cerr << "Retrying on CPU...\n";
            logline("Retrying on CPU...");
            try {
                ov::genai::LLMPipeline pipe(model_dir, "CPU");
                ov::genai::GenerationConfig cfg;
                cfg.max_new_tokens = 64;

                std::string prompt = "Say hello in one sentence.";
                std::cout << "AI: " << std::flush;

                auto streamer = [](const std::string& piece) {
                    std::cout << piece << std::flush;
                    return false;
                };

                pipe.generate(prompt, cfg, streamer);
                std::cout << "\n" << std::flush;
            } catch (const std::exception& e2) {
                std::cerr << "CPU retry failed: " << e2.what() << "\n";
                logline(std::string("CPU retry failed: ") + e2.what());
            }
        }

        std::cout << "\nPress Enter to exit...\n";
        std::string dummy;
        std::getline(std::cin, dummy);
        return 1;
    }

    logline("=== RUN END ===");
    return 0;
}