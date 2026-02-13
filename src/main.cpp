#include <openvino/genai/llm_pipeline.hpp>
#include <openvino/runtime/core.hpp>

#include <windows.h>

#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <filesystem>

// Append logs to runlog.txt (handy when dist runs outside VSCode)
static void logline(const std::string& s) {
    std::ofstream f("../runlog.txt", std::ios::app);
    f << s << std::endl;
}

// Pick NPU if available, else CPU. Also print available devices.
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
            if (d.find("NPU") != std::string::npos) {
                chosen = "NPU";
            }
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

int main(int argc, char** argv) {
    // Check command line arguments
    if (argc < 2) {
        std::cerr << "Usage: npu_wrapper.exe <model_path>\n";
        std::cerr << "Example: npu_wrapper.exe ./models/Qwen3_0_6B_ov\n";
        return 1;
    }

    // Proves which binary is running (useful when you have build/ vs dist/)
    char exePath[MAX_PATH]{0};
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);
    // Comment this out once you're confident it's the right exe:
    // MessageBoxA(nullptr, exePath, "EXE PATH", MB_OK);

    logline("=== RUN START ===");
    logline(std::string("EXE: ") + exePath);

    std::cout << "MAIN STARTED\n" << std::flush;
    logline("MAIN STARTED");

    std::string model_dir = argv[1];
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

        // Warm-up run to stabilize device performance
        std::cout << "Running warm-up...\n" << std::flush;
        pipe.generate("Hello", cfg);
        std::cout << "READY. Type prompt (exit to quit)\n" << std::flush;
        logline("READY.");

        while (true) {
            std::cout << "\nYou: " << std::flush;
            std::string prompt;
            if (!std::getline(std::cin, prompt)) break;
            if (prompt == "exit") break;

            std::cout << "AI: " << std::flush;

            // Stop the model if it starts generating the next dialogue turn
            // (TinyLlama often continues with "You:" / "User:" / "AI:" by itself)
            std::string buffer;

            auto start_time = std::chrono::high_resolution_clock::now();

            auto streamer = [&](const std::string& piece) {
                buffer += piece;

                // If the model begins a new turn marker, stop generation.
                const char* markers[] = {"\nYou:", "\nUser:", "\nAI:"};
                size_t cut = std::string::npos;

                for (auto* m : markers) {
                    size_t pos = buffer.find(m);
                    if (pos != std::string::npos) {
                        cut = pos;
                        break;
                    }
                }

                if (cut != std::string::npos) {
                    // Print only up to the marker and stop
                    std::cout << buffer.substr(0, cut) << std::flush;
                    return true; // stop generation
                }

                // Otherwise stream normally
                std::cout << piece << std::flush;
                return false; // keep generating
            };

            pipe.generate(prompt, cfg, streamer);
            
            auto end_time = std::chrono::high_resolution_clock::now();
            double elapsed = std::chrono::duration<double>(end_time - start_time).count();
            
            std::cout << "\n[Time: " << elapsed << " seconds]\n" << std::flush;
            logline("Generation time: " + std::to_string(elapsed) + " seconds");
        }
    } catch (const std::exception& e) {
        std::cerr << "\nOpenVINO GenAI exception: " << e.what() << "\n";
        logline(std::string("GenAI exception: ") + e.what());

        // If NPU fails, retry on CPU once (common when plugins/extensions aren't available)
        if (device == "NPU") {
            std::cerr << "Retrying on CPU...\n";
            logline("Retrying on CPU...");
            try {
                ov::genai::LLMPipeline pipe(model_dir, "CPU");

                ov::genai::GenerationConfig cfg;
                cfg.max_new_tokens = 64;
                cfg.temperature = 0.7f;

                std::string prompt = "Say hello in one sentence.";
                std::cout << "AI: " << std::flush;

                std::string buffer;
                auto streamer = [&](const std::string& piece) {
                    buffer += piece;

                    const char* markers[] = {"\nYou:", "\nUser:", "\nAI:"};
                    size_t cut = std::string::npos;
                    for (auto* m : markers) {
                        size_t pos = buffer.find(m);
                        if (pos != std::string::npos) { cut = pos; break; }
                    }

                    if (cut != std::string::npos) {
                        std::cout << buffer.substr(0, cut) << std::flush;
                        return true;
                    }

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
    
    // Delete the log file when done
    try {
        std::filesystem::remove("../runlog.txt");
    } catch (...) {
        // Silently ignore if deletion fails
    }
    
    return 0;
}