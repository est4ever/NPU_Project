#include <openvino/runtime/core.hpp>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include "../OpenVINO/Backend/OpenVINOBackend.h"
#include "../OpenVINO/Backend/BackendPool.h"
#include "../OpenVINO/Scheduler/OpenVINOScheduler.h"

#include <chrono>
#include <iostream>
#include <string>
#include <fstream>
#include <filesystem>

// Append logs to runlog.txt (handy when dist runs outside VSCode)
static void logline(const std::string& s) {
    std::ofstream f("runlog.txt", std::ios::app);
    f << s << std::endl;
}

static EnginePolicy parse_policy_arg(int argc, char** argv) {
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--policy") {
            if (i + 1 < argc) {
                std::string policy = argv[i + 1];
                if (policy == "PERFORMANCE") return EnginePolicy::PERFORMANCE;
                if (policy == "BATTERY_SAVER") return EnginePolicy::BATTERY_SAVER;
                if (policy == "BALANCED") return EnginePolicy::BALANCED;
            }
        }
    }
    return EnginePolicy::BATTERY_SAVER; // Default to battery saver (NPU-first)
}

static bool parse_device_override(int argc, char** argv, std::string& out) {
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--device") {
            if (i + 1 < argc) {
                out = argv[i + 1];
                return true;
            }
            out.clear();
            return true;
        }
        const std::string prefix = "--device=";
        if (arg.rfind(prefix, 0) == 0) {
            out = arg.substr(prefix.size());
            return true;
        }
    }
    out.clear();
    return false;
}

static bool has_benchmark_flag(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--benchmark") {
            return true;
        }
    }
    return false;
}

int main(int argc, char** argv) {
    // Check command line arguments
    if (argc < 2) {
        std::cerr << "Usage: npu_wrapper.exe <model_path> [options]\n";
        std::cerr << "\nOptions:\n";
        std::cerr << "  --policy PERFORMANCE|BATTERY_SAVER|BALANCED  Set device selection policy\n";
        std::cerr << "  --device CPU|GPU|NPU                         Override device selection\n";
        std::cerr << "  --benchmark                                   Run benchmarks and load on all devices\n";
        std::cerr << "\nExamples:\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy BATTERY_SAVER\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device NPU\n";
        std::cerr << "  npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --benchmark\n";
        return 1;
    }

    // Proves which binary is running (useful when you have build/ vs dist/)
    char exePath[MAX_PATH]{0};
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);

    logline("=== RUN START ===");
    logline(std::string("EXE: ") + exePath);

    std::cout << "MAIN STARTED\n" << std::flush;
    logline("MAIN STARTED");

    std::string model_dir = argv[1];
    std::cout << "Model dir: " << model_dir << "\n" << std::flush;
    logline("Model dir: " + model_dir);

    // Initialize scheduler
    OpenVINOScheduler scheduler;
    
    // Check for policy argument
    EnginePolicy policy = parse_policy_arg(argc, argv);
    std::cout << "Policy: " << (policy == EnginePolicy::PERFORMANCE ? "PERFORMANCE" : 
                                   policy == EnginePolicy::BATTERY_SAVER ? "BATTERY_SAVER" : "BALANCED") << "\n" << std::flush;
    logline("Policy: ");
    
    // Check for benchmark mode
    bool benchmark_mode = has_benchmark_flag(argc, argv);
    
    // Check for device override
    std::string device_override;
    bool device_arg_found = parse_device_override(argc, argv, device_override);
    if (device_arg_found && device_override.empty()) {
        std::cerr << "Error: --device requires a value (CPU|GPU|NPU)\n";
        return 1;
    }

    try {
        if (benchmark_mode) {
            // ============ MULTI-DEVICE MODE ============
            std::cout << "\n[MULTI-DEVICE MODE ENABLED]\n";
            logline("Multi-device mode enabled");
            
            // Get all available devices
            auto available_devices = scheduler.discover_devices();
            
            // Filter devices to test (skip AUTO, HETERO, etc.)
            std::vector<std::string> devices_to_test;
            for (const auto& dev : available_devices) {
                if (dev == "CPU" || dev == "GPU" || dev == "NPU") {
                    devices_to_test.push_back(dev);
                }
            }
            
            // Run benchmarks
            auto benchmarks = scheduler.benchmark_devices(model_dir, devices_to_test);
            
            // Get best device based on benchmarks
            std::string best_device = scheduler.get_best_device_from_benchmarks(benchmarks, policy);
            
            // Load model on all tested devices
            BackendPool pool;
            pool.load_on_devices(model_dir, devices_to_test);
            pool.set_active_device(best_device);
            
            std::cout << "\nREADY. Type prompt (exit to quit, stats/devices/auto/switch [device])\n" << std::flush;
            logline("READY (multi-device).");
            
            bool auto_switch_enabled = true;  // Auto-switching enabled by default
            
            while (true) {
                std::cout << "\nYou [" << pool.get_active_device() << (auto_switch_enabled ? " AUTO" : "") << "]: " << std::flush;
                std::string prompt;
                if (!std::getline(std::cin, prompt)) break;
                if (prompt == "exit") break;
                
                if (prompt == "stats") {
                    pool.print_stats();
                    continue;
                }
                
                // Check for switch command
                if (prompt.rfind("switch ", 0) == 0) {
                    std::string target_device = prompt.substr(7);
                    pool.set_active_device(target_device);
                    continue;
                }
                
                // Show available devices
                if (prompt == "devices") {
                    std::cout << "Loaded devices:\n";
                    for (const auto& dev : pool.get_loaded_devices()) {
                        std::cout << "  - " << dev << (dev == pool.get_active_device() ? " (active)" : "") << "\n";
                    }
                    continue;
                }
                
                // Toggle auto-switching
                if (prompt == "auto") {
                    auto_switch_enabled = !auto_switch_enabled;
                    std::cout << "[Auto-switching " << (auto_switch_enabled ? "ENABLED" : "DISABLED") << "]\n";
                    continue;
                }
                
                auto start_time = std::chrono::high_resolution_clock::now();
                pool.generate_stream(prompt);
                
                auto end_time = std::chrono::high_resolution_clock::now();
                double elapsed = std::chrono::duration<double>(end_time - start_time).count();
                
                std::cout << "\n[Device: " << pool.get_active_device() << ", Time: " << elapsed << " seconds]\n" << std::flush;
                logline("Generation on " + pool.get_active_device() + ": " + std::to_string(elapsed) + " seconds");
                
                // Automatic device selection based on performance (if enabled)
                if (auto_switch_enabled) {
                    std::string prev_device = pool.get_active_device();
                    std::string new_device = pool.auto_select_best_device(benchmarks);
                    if (new_device != prev_device) {
                        pool.set_active_device(new_device);
                    }
                }
            }
            
        } else {
            // ============ SINGLE-DEVICE MODE ============
            // Get device based on policy or override
            std::string device;
            if (!device_override.empty()) {
                device = device_override;
                std::cout << "Device override: " << device << "\n" << std::flush;
                logline("Device override: " + device);
            } else {
                device = scheduler.get_optimal_device(policy);
            }
            std::cout << "Device chosen: " << device << "\n" << std::flush;
            logline("Device chosen: " + device);
            
            OpenVINOBackend backend;
            backend.load_model(model_dir, device);

            std::cout << "READY. Type prompt (exit to quit)\n" << std::flush;
            logline("READY.");

            while (true) {
                std::cout << "\nYou: " << std::flush;
                std::string prompt;
                if (!std::getline(std::cin, prompt)) break;
                if (prompt == "exit") break;

                if (prompt == "stats") {
                    backend.print_stats();
                    continue;
                }

                auto start_time = std::chrono::high_resolution_clock::now();
                backend.generate_stream(prompt);
                
                auto end_time = std::chrono::high_resolution_clock::now();
                double elapsed = std::chrono::duration<double>(end_time - start_time).count();
                
                std::cout << "\n[Time: " << elapsed << " seconds]\n" << std::flush;
                logline("Generation time: " + std::to_string(elapsed) + " seconds");
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "\nOpenVINO GenAI exception: " << e.what() << "\n";
        logline(std::string("GenAI exception: ") + e.what());

        std::cout << "\nPress Enter to exit...\n";
        std::string dummy;
        std::getline(std::cin, dummy);
        return 1;
    }

    logline("=== RUN END ===");
    
    // Delete the log file when done
    try {
        std::filesystem::remove("runlog.txt");
    } catch (...) {
        // Silently ignore if deletion fails
    }
    
    return 0;
}