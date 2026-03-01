#include "RestAPIServer.h"
#include "../OpenVINO/Backend/OpenVINOBackend.h"
#include <httplib.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <sstream>
#include <chrono>
#include <iomanip>

using json = nlohmann::json;

RestAPIServer::RestAPIServer(BackendPool* pool, int port)
    : backend_pool_(pool), port_(port), running_(false) {
    server_ = std::make_unique<httplib::Server>();
    
    // Set up CORS headers for all responses
    server_->set_default_headers({
        {"Access-Control-Allow-Origin", "*"},
        {"Access-Control-Allow-Methods", "GET, POST, OPTIONS"},
        {"Access-Control-Allow-Headers", "Content-Type, Authorization"}
    });
    
    // Register endpoints
    server_->Post("/v1/chat/completions", [this](const httplib::Request& req, httplib::Response& res) {
        handle_chat_completions(req, res);
    });
    
    server_->Get("/v1/models", [this](const httplib::Request& req, httplib::Response& res) {
        handle_list_models(req, res);
    });
    
    server_->Get("/health", [this](const httplib::Request& req, httplib::Response& res) {
        handle_health(req, res);
    });
    
    server_->Options(".*", [](const httplib::Request&, httplib::Response& res) {
        res.status = 204; // No Content
    });
}

RestAPIServer::~RestAPIServer() {
    stop();
}

void RestAPIServer::start() {
    running_ = true;
    std::cout << "[RestAPI] Starting server on http://localhost:" << port_ << "\n";
    std::cout << "[RestAPI] Endpoints:\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/chat/completions\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/models\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/health\n";
    
    if (!server_->listen("0.0.0.0", port_)) {
        std::cerr << "[RestAPI] Failed to start server on port " << port_ << "\n";
        running_ = false;
    }
}

void RestAPIServer::stop() {
    if (running_) {
        std::cout << "[RestAPI] Stopping server...\n";
        server_->stop();
        running_ = false;
    }
}

bool RestAPIServer::is_running() const {
    return running_;
}

void RestAPIServer::handle_chat_completions(const httplib::Request& req, httplib::Response& res) {
    try {
        // Parse incoming JSON request
        json request_body = json::parse(req.body);
        
        // Extract parameters
        std::string model = request_body.value("model", "openvino");
        bool stream = request_body.value("stream", false);
        float temperature = request_body.value("temperature", 0.7f);
        int max_tokens = request_body.value("max_tokens", 128);
        
        // Build prompt from messages
        std::stringstream prompt_builder;
        if (request_body.contains("messages") && request_body["messages"].is_array()) {
            for (const auto& message : request_body["messages"]) {
                std::string role = message.value("role", "user");
                std::string content = message.value("content", "");
                
                if (role == "system") {
                    prompt_builder << "System: " << content << "\n";
                } else if (role == "user") {
                    prompt_builder << "User: " << content << "\n";
                } else if (role == "assistant") {
                    prompt_builder << "Assistant: " << content << "\n";
                }
            }
            prompt_builder << "Assistant: ";
        } else {
            // Fallback to "prompt" field if no messages
            prompt_builder << request_body.value("prompt", "");
        }
        
        std::string prompt = prompt_builder.str();
        
        if (stream) {
            // Streaming response (SSE format)
            res.set_header("Content-Type", "text/event-stream");
            res.set_header("Cache-Control", "no-cache");
            res.set_header("Connection", "keep-alive");
            
            // Generate with streaming
            std::string full_response;
            std::string chunk_id = "chatcmpl-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count());
            
            auto stream_callback = [&](const std::string& piece) -> ov::genai::StreamingStatus {
                full_response += piece;
                
                // Create SSE chunk in OpenAI format
                json chunk = {
                    {"id", chunk_id},
                    {"object", "chat.completion.chunk"},
                    {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                    {"model", model},
                    {"choices", json::array({
                        {
                            {"index", 0},
                            {"delta", {{"content", piece}}},
                            {"finish_reason", nullptr}
                        }
                    })}
                };
                
                res.set_content_provider(
                    "text/event-stream",
                    [chunk_str = "data: " + chunk.dump() + "\n\n"](size_t offset, httplib::DataSink& sink) {
                        sink.write(chunk_str.data(), chunk_str.size());
                        return true;
                    }
                );
                
                return ov::genai::StreamingStatus::RUNNING;
            };
            
            // Call backend with streaming
            auto* backend = dynamic_cast<OpenVINOBackend*>(backend_pool_->get_active_backend());
            if (!backend) {
                throw std::runtime_error("Backend is not OpenVINOBackend");
            }
            auto output = backend->generate_output(
                prompt, max_tokens, temperature, false
            );
            
            // Send final chunk
            json final_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", json::object()},
                        {"finish_reason", "stop"}
                    }
                })}
            };
            
            std::string final_data = "data: " + final_chunk.dump() + "\n\ndata: [DONE]\n\n";
            res.body = final_data;
            
        } else {
            // Non-streaming response
            auto* backend = dynamic_cast<OpenVINOBackend*>(backend_pool_->get_active_backend());
            if (!backend) {
                throw std::runtime_error("Backend is not OpenVINOBackend");
            }
            auto output = backend->generate_output(
                prompt, max_tokens, temperature, false
            );
            
            // Format response in OpenAI format
            json response = {
                {"id", "chatcmpl-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count())},
                {"object", "chat.completion"},
                {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"message", {
                            {"role", "assistant"},
                            {"content", output.text}
                        }},
                        {"finish_reason", "stop"}
                    }
                })},
                {"usage", {
                    {"prompt_tokens", 0},  // Would need tokenizer access to compute
                    {"completion_tokens", output.token_ids.size()},
                    {"total_tokens", output.token_ids.size()}
                }}
            };
            
            res.set_content(response.dump(), "application/json");
        }
        
    } catch (const json::exception& e) {
        json error_response = {
            {"error", {
                {"message", "Invalid JSON: " + std::string(e.what())},
                {"type", "invalid_request_error"},
                {"code", "invalid_json"}
            }}
        };
        res.status = 400;
        res.set_content(error_response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error_response = {
            {"error", {
                {"message", std::string(e.what())},
                {"type", "internal_error"},
                {"code", "internal_error"}
            }}
        };
        res.status = 500;
        res.set_content(error_response.dump(), "application/json");
    }
}

void RestAPIServer::handle_list_models(const httplib::Request& req, httplib::Response& res) {
    json response = {
        {"object", "list"},
        {"data", json::array({
            {
                {"id", "openvino-local"},
                {"object", "model"},
                {"created", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())},
                {"owned_by", "local"},
                {"permission", json::array()},
                {"root", "openvino-local"},
                {"parent", nullptr}
            }
        })}
    };
    
    res.set_content(response.dump(), "application/json");
}

void RestAPIServer::handle_health(const httplib::Request& req, httplib::Response& res) {
    json response = {
        {"status", "healthy"},
        {"backend", backend_pool_->get_active_device()}
    };
    
    res.set_content(response.dump(), "application/json");
}
