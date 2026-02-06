#include "openvino/genai/llm_pipeline.hpp"
#include <iostream>

int main() {
    // 1. Path to your model folder (Make sure this exists on your PC!)
    std::string model_path = "./models/TinyLlama_ov";
    
    // 2. The Device: Use "CPU" for your desktop PC. 
    // You will change this to "NPU" on your Core Ultra 9 laptop.
    std::string device = "CPU"; 

    try {
        std::cout << "Loading model to " << device << "..." << std::endl;
        ov::genai::LLMPipeline pipe(model_path, device);

        std::cout << "AI is ready! Type your message (or 'exit'):" << std::endl;
        std::string prompt;

        while (true) {
            std::cout << "\nYou: ";
            std::getline(std::cin, prompt);
            if (prompt == "exit") break;

            std::cout << "AI: ";
            // Streamer lambda prints words as they are generated
            auto streamer = [](std::string word) {
                std::cout << word << std::flush;
                return false; 
            };

            pipe.generate(prompt, ov::genai::GenerationConfig(), streamer);
            std::cout << std::endl;
        }
    } catch (const std::exception& e) {
        std::cerr << "Exception: " << e.what() << std::endl;
    }

    return 0;
}