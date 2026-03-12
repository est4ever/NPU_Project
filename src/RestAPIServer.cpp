#include "RestAPIServer.h"
#include <httplib.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <sstream>
#include <chrono>
#include <iomanip>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <filesystem>
#include <optional>
#include "../OpenVINO/Backend/KVCacheMonitor.h"

using json = nlohmann::json;

RestAPIServer::RestAPIServer(BackendPool* pool, int port)
    : RestAPIServer(pool, nullptr, port) {}

RestAPIServer::RestAPIServer(BackendPool* pool, RuntimeConfig* config, int port)
    : RestAPIServer(pool, config, nullptr, port) {}

namespace {
const char* kRegistryDir = "./registry";
const char* kModelsRegistryPath = "./registry/models_registry.json";
const char* kBackendsRegistryPath = "./registry/backends_registry.json";

void ensure_registry_dir() {
    std::error_code ec;
    std::filesystem::create_directories(kRegistryDir, ec);
}

json default_models_registry() {
    return {
        {"schema", 1},
        {"selected_model", "openvino-local"},
        {"models", json::array({
            {
                {"id", "openvino-local"},
                {"path", "./models/Qwen2.5-0.5B-Instruct"},
                {"format", "openvino"},
                {"backend", "openvino"},
                {"status", "ready"}
            }
        })}
    };
}

json default_backends_registry() {
    return {
        {"schema", 1},
        {"selected_backend", "openvino"},
        {"backends", json::array({
            {
                {"id", "openvino"},
                {"type", "builtin"},
                {"entrypoint", "dist/npu_wrapper.exe"},
                {"formats", json::array({"openvino"})},
                {"status", "ready"}
            }
        })}
    };
}

json load_registry(const std::string& path, const json& defaults) {
    ensure_registry_dir();
    std::ifstream in(path);
    if (!in.is_open()) {
        return defaults;
    }
    try {
        return json::parse(in);
    } catch (...) {
        return defaults;
    }
}

void save_registry(const std::string& path, const json& data) {
    ensure_registry_dir();
    std::ofstream out(path, std::ios::trunc);
    out << data.dump(2);
}

json load_models_registry() {
    json reg = load_registry(kModelsRegistryPath, default_models_registry());
    if (!reg.contains("models") || !reg["models"].is_array()) {
        reg["models"] = json::array();
    }
    if (!reg.contains("selected_model") || !reg["selected_model"].is_string()) {
        reg["selected_model"] = "openvino-local";
    }
    return reg;
}

json load_backends_registry() {
    json reg = load_registry(kBackendsRegistryPath, default_backends_registry());
    if (!reg.contains("backends") || !reg["backends"].is_array()) {
        reg["backends"] = json::array();
    }
    if (!reg.contains("selected_backend") || !reg["selected_backend"].is_string()) {
        reg["selected_backend"] = "openvino";
    }
    return reg;
}

bool has_registry_item(const json& arr, const std::string& id) {
    for (const auto& item : arr) {
        if (item.is_object() && item.value("id", "") == id) {
            return true;
        }
    }
    return false;
}

std::string trim_copy(const std::string& s) {
    const auto begin = std::find_if_not(s.begin(), s.end(), [](unsigned char ch) { return std::isspace(ch) != 0; });
    if (begin == s.end()) {
        return "";
    }
    const auto end = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char ch) { return std::isspace(ch) != 0; }).base();
    return std::string(begin, end);
}

std::string to_lower_copy(const std::string& s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return out;
}

bool starts_with(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

std::string to_upper_copy(const std::string& s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return out;
}

bool parse_command(const std::string& raw, std::string& command, std::string& argument) {
    const std::string trimmed = trim_copy(raw);
    if (trimmed.empty()) {
        return false;
    }

    const std::string lower = to_lower_copy(trimmed);
    if (lower == "help" || lower == "/help") {
        command = "help";
        argument.clear();
        return true;
    }
    if (lower == "stats" || lower == "/stats") {
        command = "stats";
        argument.clear();
        return true;
    }
    if (lower == "devices" || lower == "/devices") {
        command = "devices";
        argument.clear();
        return true;
    }
    if (lower == "status" || lower == "/status" || lower == "info" || lower == "/info") {
        command = "status";
        argument.clear();
        return true;
    }
    if (lower == "health" || lower == "/health") {
        command = "health";
        argument.clear();
        return true;
    }
    if (lower == "model" || lower == "/model" || lower == "models" || lower == "/models") {
        command = "model";
        argument.clear();
        return true;
    }
    if (lower == "memory" || lower == "/memory") {
        command = "memory";
        argument.clear();
        return true;
    }
    if (starts_with(lower, "switch ") || starts_with(lower, "/switch ")) {
        command = "switch";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (starts_with(lower, "policy ") || starts_with(lower, "/policy ")) {
        command = "policy";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (starts_with(lower, "json ") || starts_with(lower, "/json ")) {
        command = "json";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "split-prefill ") || starts_with(lower, "/split-prefill ")) {
        command = "split-prefill";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "context-routing ") || starts_with(lower, "/context-routing ")) {
        command = "context-routing";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "optimize-memory ") || starts_with(lower, "/optimize-memory ")) {
        command = "optimize-memory";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }
    if (starts_with(lower, "threshold ") || starts_with(lower, "/threshold ")) {
        command = "threshold";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "" : trim_copy(trimmed.substr(space + 1));
        return true;
    }
    if (lower == "auto" || lower == "/auto") {
        command = "auto";
        argument.clear();
        return true;
    }
    if (lower == "benchmark" || lower == "/benchmark") {
        command = "benchmark";
        argument.clear();
        return true;
    }
    if (lower == "calibrate" || lower == "/calibrate") {
        command = "calibrate";
        argument.clear();
        return true;
    }
    if (lower == "metrics" || lower == "/metrics") {
        command = "metrics";
        argument = "last";
        return true;
    }
    if (starts_with(lower, "metrics ") || starts_with(lower, "/metrics ")) {
        command = "metrics";
        const size_t space = trimmed.find(' ');
        argument = (space == std::string::npos) ? "last" : to_lower_copy(trim_copy(trimmed.substr(space + 1)));
        return true;
    }

    return false;
}

std::optional<json> read_latest_metrics_record() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    for (const auto& path : candidates) {
        std::ifstream in(path);
        if (!in.is_open()) {
            continue;
        }

        std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        content.erase(std::remove(content.begin(), content.end(), '\0'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\r'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\n'), content.end());

        // Strip UTF-8 BOM if present.
        if (content.size() >= 3 &&
            static_cast<unsigned char>(content[0]) == 0xEF &&
            static_cast<unsigned char>(content[1]) == 0xBB &&
            static_cast<unsigned char>(content[2]) == 0xBF) {
            content = content.substr(3);
        }

        std::optional<json> last_record;
        for (size_t i = 0; i < content.size(); ++i) {
            if (content[i] != '{') {
                continue;
            }

            bool in_string = false;
            bool escaped = false;
            int depth = 0;
            for (size_t j = i; j < content.size(); ++j) {
                const char ch = content[j];

                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }

                if (ch == '"') {
                    in_string = true;
                    continue;
                }
                if (ch == '{') {
                    ++depth;
                } else if (ch == '}') {
                    --depth;
                    if (depth == 0) {
                        const std::string candidate = content.substr(i, j - i + 1);
                        try {
                            last_record = json::parse(candidate);
                        } catch (...) {
                            // Keep scanning for a valid object.
                        }
                        break;
                    }
                }
            }
        }

        if (last_record.has_value()) {
            return last_record;
        }
    }

    return std::nullopt;
}

std::vector<json> read_all_metrics_records() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    for (const auto& path : candidates) {
        std::ifstream in(path);
        if (!in.is_open()) {
            continue;
        }

        std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        content.erase(std::remove(content.begin(), content.end(), '\0'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\r'), content.end());
        content.erase(std::remove(content.begin(), content.end(), '\n'), content.end());

        if (content.size() >= 3 &&
            static_cast<unsigned char>(content[0]) == 0xEF &&
            static_cast<unsigned char>(content[1]) == 0xBB &&
            static_cast<unsigned char>(content[2]) == 0xBF) {
            content = content.substr(3);
        }

        std::vector<json> records;
        for (size_t i = 0; i < content.size(); ++i) {
            if (content[i] != '{') {
                continue;
            }

            bool in_string = false;
            bool escaped = false;
            int depth = 0;
            for (size_t j = i; j < content.size(); ++j) {
                const char ch = content[j];
                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }

                if (ch == '"') {
                    in_string = true;
                    continue;
                }
                if (ch == '{') {
                    ++depth;
                } else if (ch == '}') {
                    --depth;
                    if (depth == 0) {
                        const std::string candidate = content.substr(i, j - i + 1);
                        try {
                            records.push_back(json::parse(candidate));
                        } catch (...) {
                            // Ignore malformed object and continue.
                        }
                        break;
                    }
                }
            }
        }

        if (!records.empty()) {
            return records;
        }
    }

    return {};
}

size_t clear_metrics_files() {
    const std::vector<std::string> candidates = {
        "./metrics.ndjson",
        "../metrics.ndjson"
    };

    size_t removed = 0;
    for (const auto& path : candidates) {
        std::error_code ec;
        if (std::filesystem::exists(path, ec) && !ec) {
            if (std::filesystem::remove(path, ec) && !ec) {
                ++removed;
            }
        }
    }
    return removed;
}
}

RestAPIServer::RestAPIServer(BackendPool* pool, RuntimeConfig* config, KVCacheMonitor* kv_monitor, int port)
    : backend_pool_(pool), config_(config ? config : &default_config_), kv_monitor_(kv_monitor), port_(port), running_(false) {
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
    
    // ===== CLI Endpoints - For terminal control commands =====
    server_->Get("/v1/cli/status", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_status(req, res);
    });
    
    server_->Post("/v1/cli/device/switch", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_device_switch(req, res);
    });
    
    server_->Post("/v1/cli/policy", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_policy(req, res);
    });
    
    server_->Post("/v1/cli/feature/(.*)", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_feature_toggle(req, res);
    });
    
    server_->Post("/v1/cli/threshold", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_threshold(req, res);
    });
    
    server_->Get("/v1/cli/metrics", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_metrics(req, res);
    });

    server_->Get("/v1/cli/model/list", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_list(req, res);
    });

    server_->Post("/v1/cli/model/import", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_import(req, res);
    });

    server_->Post("/v1/cli/model/select", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_model_select(req, res);
    });

    server_->Get("/v1/cli/backend/list", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_list(req, res);
    });

    server_->Post("/v1/cli/backend/add", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_add(req, res);
    });

    server_->Post("/v1/cli/backend/select", [this](const httplib::Request& req, httplib::Response& res) {
        handle_cli_backend_select(req, res);
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
    std::cout << "[RestAPI] Chat Endpoint:\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/chat/completions (pure chat only)\n";
    std::cout << "[RestAPI] Information Endpoints:\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/models\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/health\n";
    std::cout << "[RestAPI] CLI Control Endpoints (use npu_cli.ps1 tool):\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/status\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/device/switch\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/policy\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/feature/{feature}\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/threshold\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/metrics\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/model/list\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/model/import\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/model/select\n";
    std::cout << "  - GET  http://localhost:" << port_ << "/v1/cli/backend/list\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/backend/add\n";
    std::cout << "  - POST http://localhost:" << port_ << "/v1/cli/backend/select\n";
    std::cout.flush();
    
    std::cout << "[RestAPI] Attempting to bind to 0.0.0.0:" << port_ << "...\n";
    std::cout.flush();
    
    try {
        // First bind to the port (non-blocking)
        if (!server_->bind_to_port("0.0.0.0", port_)) {
            std::cerr << "[RestAPI] FAILED - Could not bind to port " << port_ << " (may be in use?)\n";
            std::cerr.flush();
            running_ = false;
            return;
        }
        
        std::cout << "[RestAPI] Successfully bound to port " << port_ << "\n";
        std::cout << "[RestAPI] Server is now READY and listening for requests\n";
        std::cout.flush();
        
        // Now start the blocking event loop
        if (!server_->listen_after_bind()) {
            std::cerr << "[RestAPI] Error in listen event loop\n";
            std::cerr.flush();
            running_ = false;
            return;
        }
    } catch (const std::exception& e) {
        std::cerr << "[RestAPI] EXCEPTION: " << e.what() << "\n";
        std::cerr.flush();
        running_ = false;
        return;
    } catch (...) {
        std::cerr << "[RestAPI] UNKNOWN EXCEPTION\n";
        std::cerr.flush();
        running_ = false;
        return;
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
        if (max_tokens <= 0) {
            max_tokens = 128;
        }
        
        // Build prompt from messages
        std::stringstream prompt_builder;
        std::string last_user_message;
        if (request_body.contains("messages") && request_body["messages"].is_array()) {
            for (const auto& message : request_body["messages"]) {
                std::string role = message.value("role", "user");
                std::string content;

                // OpenWebUI may send message.content as either a plain string or an array of parts.
                if (message.contains("content")) {
                    const auto& raw_content = message["content"];
                    if (raw_content.is_string()) {
                        content = raw_content.get<std::string>();
                    } else if (raw_content.is_array()) {
                        for (const auto& part : raw_content) {
                            if (part.is_string()) {
                                content += part.get<std::string>();
                            } else if (part.is_object()) {
                                if (part.value("type", "") == "text" && part.contains("text") && part["text"].is_string()) {
                                    content += part["text"].get<std::string>();
                                }
                            }
                        }
                    }
                }
                
                if (role == "system") {
                    prompt_builder << "System: " << content << "\n";
                } else if (role == "user") {
                    last_user_message = content;
                    prompt_builder << "User: " << content << "\n";
                } else if (role == "assistant") {
                    prompt_builder << "Assistant: " << content << "\n";
                }
            }
            prompt_builder << "Assistant: ";
        } else {
            // Fallback to "prompt" field if no messages
            last_user_message = request_body.value("prompt", "");
            prompt_builder << last_user_message;
        }
        
        std::string prompt = prompt_builder.str();

        auto* backend = backend_pool_->get_active_backend();
        if (!backend) {
            throw std::runtime_error("No active backend is available");
        }

        std::string command_name;
        std::string command_arg;
        std::string response_text;
        size_t completion_tokens = 0;

        // Keep chat pure: if a user types a control command in chat, guide them to terminal CLI.
        if (parse_command(last_user_message, command_name, command_arg)) {
            response_text =
                "Control commands are now terminal-only.\n"
                "Use: .\\npu_cli.ps1 -Command help\n\n"
                "Examples:\n"
                "- .\\npu_cli.ps1 -Command status\n"
                "- .\\npu_cli.ps1 -Command switch -Arguments \"GPU\"\n"
                "- .\\npu_cli.ps1 -Command policy -Arguments \"PERFORMANCE\"\n"
                "- .\\npu_cli.ps1 -Command metrics -Arguments \"summary\"";
            completion_tokens = 0;
        } else {
            // Normal chat generation path.
            auto output = backend->generate_output(
                prompt, max_tokens, temperature, false
            );
            response_text = output.text;
            completion_tokens = output.token_ids.size();
        }
        
        if (stream) {

            const auto created = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
            const std::string chunk_id = "chatcmpl-" + std::to_string(std::chrono::system_clock::now().time_since_epoch().count());

            json role_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", {{"role", "assistant"}}},
                        {"finish_reason", nullptr}
                    }
                })}
            };

            json content_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", {{"content", response_text}}},
                        {"finish_reason", nullptr}
                    }
                })}
            };

            json final_chunk = {
                {"id", chunk_id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", model},
                {"choices", json::array({
                    {
                        {"index", 0},
                        {"delta", json::object()},
                        {"finish_reason", "stop"}
                    }
                })}
            };
            std::string sse_data;
            sse_data += "data: " + role_chunk.dump() + "\n\n";
            sse_data += "data: " + content_chunk.dump() + "\n\n";
            sse_data += "data: " + final_chunk.dump() + "\n\n";
            sse_data += "data: [DONE]\n\n";

            res.set_content(sse_data, "text/event-stream");
            
        } else {
            // Non-streaming response
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
                            {"content", response_text}
                        }},
                        {"finish_reason", "stop"}
                    }
                })},
                {"usage", {
                    {"prompt_tokens", 0},  // Would need tokenizer access to compute
                    {"completion_tokens", completion_tokens},
                    {"total_tokens", completion_tokens}
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

// ===== CLI Endpoint Implementations =====

void RestAPIServer::handle_cli_status(const httplib::Request& req, httplib::Response& res) {
    try {
        auto devices = backend_pool_->get_loaded_devices();
        BackendMetrics metrics = backend_pool_->get_active_metrics();
        
        json response = {
            {"policy", policy_to_string(config_->get_policy())},
            {"active_device", backend_pool_->get_active_device()},
            {"devices", devices},
            {"json_output", config_->get_json_mode() ? "ON" : "OFF"},
            {"split_prefill", config_->get_split_prefill() ? "ON" : "OFF"},
            {"context_routing", config_->get_context_routing() ? "ON" : "OFF"},
            {"optimize_memory", config_->get_enable_kv_paging() ? "ON" : "OFF"},
            {"ttft_ms", metrics.ttft_ms},
            {"tpot_ms", metrics.tpot_ms},
            {"throughput", metrics.throughput}
        };

        const json models_reg = load_models_registry();
        const json backends_reg = load_backends_registry();
        response["selected_model"] = models_reg.value("selected_model", "openvino-local");
        response["selected_backend"] = backends_reg.value("selected_backend", "openvino");
        
        if (config_->get_split_prefill()) {
            response["prefill_device"] = config_->prefill_device;
            response["decode_device"] = config_->decode_device;
            response["threshold"] = config_->get_prefill_threshold_high();
        }
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_device_switch(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        std::string device = request_body.value("device", "");
        
        if (device.empty()) {
            res.status = 400;
            res.set_content(R"({"error": "device parameter required"})", "application/json");
            return;
        }
        
        backend_pool_->set_active_device(device);
        std::string actual_device = backend_pool_->get_active_device();
        
        json response = {
            {"new_active_device", actual_device},
            {"success", actual_device == device}
        };
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_policy(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        std::string policy_str = request_body.value("policy", "");
        
        if (policy_str.empty()) {
            res.status = 400;
            res.set_content(R"({"error": "policy parameter required"})", "application/json");
            return;
        }
        
        EnginePolicy new_policy = string_to_policy(policy_str);
        config_->set_policy(new_policy);
        
        json response = {
            {"new_policy", policy_to_string(new_policy)},
            {"success", true}
        };
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_feature_toggle(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        bool enabled = request_body.value("enabled", false);
        
        // Extract feature name from path
        std::string path = req.path;
        size_t last_slash = path.find_last_of('/');
        std::string feature = (last_slash != std::string::npos) ? path.substr(last_slash + 1) : "";
        
        if (feature.empty()) {
            res.status = 400;
            res.set_content(R"({"error": "feature not specified in path"})", "application/json");
            return;
        }
        
        json response = {{"feature", feature}};
        
        if (feature == "json") {
            config_->set_json_mode(enabled);
            response["status"] = enabled ? "enabled" : "disabled";
        } else if (feature == "split-prefill") {
            if (enabled && backend_pool_->get_loaded_devices().size() < 2) {
                response["error"] = "At least 2 devices required";
                response["success"] = false;
            } else {
                config_->set_split_prefill(enabled);
                response["status"] = enabled ? "enabled" : "disabled";
                response["success"] = true;
            }
        } else if (feature == "context-routing") {
            config_->set_context_routing(enabled);
            response["status"] = enabled ? "enabled" : "disabled";
            response["success"] = true;
        } else if (feature == "optimize-memory") {
            config_->set_enable_kv_paging(enabled);
            response["status"] = enabled ? "enabled" : "disabled";
            response["success"] = true;
        } else {
            res.status = 400;
            json error = {{"error", "Unknown feature: " + feature}};
            res.set_content(error.dump(), "application/json");
            return;
        }
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_threshold(const httplib::Request& req, httplib::Response& res) {
    try {
        json request_body = json::parse(req.body);
        int threshold = request_body.value("threshold", 0);
        
        if (threshold <= 0) {
            res.status = 400;
            res.set_content(R"({"error": "threshold must be positive"})", "application/json");
            return;
        }
        
        config_->set_prefill_threshold_high(threshold);
        config_->set_prefill_threshold_low(std::max(1, static_cast<int>(threshold * 0.8)));
        
        json response = {
            {"new_threshold", threshold},
            {"low_threshold", config_->get_prefill_threshold_low()},
            {"success", true}
        };
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_metrics(const httplib::Request& req, httplib::Response& res) {
    try {
        std::string mode = "last";
        if (req.has_param("mode")) {
            mode = req.get_param_value("mode");
        }
        
        json response;
        
        if (mode == "last") {
            const auto record = read_latest_metrics_record();
            if (!record.has_value()) {
                response = {{"error", "No metrics record found"}};
                res.status = 404;
            } else {
                response = record.value();
            }
        } else if (mode == "summary") {
            const auto records = read_all_metrics_records();
            if (records.empty()) {
                response = {{"error", "No metrics records found"}};
                res.status = 404;
            } else {
                double ttft_sum = 0.0, tpot_sum = 0.0, throughput_sum = 0.0;
                int ttft_count = 0, tpot_count = 0, throughput_count = 0;
                
                for (const auto& r : records) {
                    if (r.contains("ttft_ms") && r["ttft_ms"].is_number()) {
                        ttft_sum += r["ttft_ms"].get<double>();
                        ++ttft_count;
                    }
                    if (r.contains("tpot_ms") && r["tpot_ms"].is_number()) {
                        tpot_sum += r["tpot_ms"].get<double>();
                        ++tpot_count;
                    }
                    if (r.contains("throughput_tok_s") && r["throughput_tok_s"].is_number()) {
                        throughput_sum += r["throughput_tok_s"].get<double>();
                        ++throughput_count;
                    }
                }
                
                response = {
                    {"record_count", records.size()},
                    {"avg_ttft_ms", ttft_count > 0 ? ttft_sum / ttft_count : 0.0},
                    {"avg_tpot_ms", tpot_count > 0 ? tpot_sum / tpot_count : 0.0},
                    {"avg_throughput", throughput_count > 0 ? throughput_sum / throughput_count : 0.0}
                };
            }
        } else if (mode == "clear") {
            const size_t removed = clear_metrics_files();
            response = {
                {"cleared", removed > 0},
                {"files_removed", removed}
            };
        } else {
            res.status = 400;
            response = {{"error", "Invalid mode. Use: last, summary, or clear"}};
        }
        
        res.set_content(response.dump(), "application/json");
    } catch (const std::exception& e) {
        json error = {{"error", e.what()}};
        res.status = 500;
        res.set_content(error.dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_model_list(const httplib::Request& req, httplib::Response& res) {
    try {
        json models_reg = load_models_registry();
        save_registry(kModelsRegistryPath, models_reg);
        res.set_content(models_reg.dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_model_import(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = trim_copy(body.value("id", ""));
        const std::string path = trim_copy(body.value("path", ""));
        const std::string format = to_lower_copy(trim_copy(body.value("format", "openvino")));
        const std::string backend = to_lower_copy(trim_copy(body.value("backend", "openvino")));
        const std::string status = trim_copy(body.value("status", "ready"));

        if (id.empty() || path.empty()) {
            res.status = 400;
            res.set_content(R"({"error":"id and path are required"})", "application/json");
            return;
        }

        json models_reg = load_models_registry();
        bool updated = false;
        for (auto& item : models_reg["models"]) {
            if (item.value("id", "") == id) {
                item["path"] = path;
                item["format"] = format;
                item["backend"] = backend;
                item["status"] = status;
                updated = true;
                break;
            }
        }

        if (!updated) {
            models_reg["models"].push_back({
                {"id", id},
                {"path", path},
                {"format", format},
                {"backend", backend},
                {"status", status}
            });
        }

        if (!models_reg.contains("selected_model") || models_reg["selected_model"].get<std::string>().empty()) {
            models_reg["selected_model"] = id;
        }

        save_registry(kModelsRegistryPath, models_reg);
        res.set_content(json({
            {"success", true},
            {"updated", updated},
            {"id", id},
            {"note", "Model registered. Restart stack to load a newly selected model."}
        }).dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_model_select(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = trim_copy(body.value("id", ""));
        if (id.empty()) {
            res.status = 400;
            res.set_content(R"({"error":"id is required"})", "application/json");
            return;
        }

        json models_reg = load_models_registry();
        if (!has_registry_item(models_reg["models"], id)) {
            res.status = 404;
            res.set_content(json({{"error", "Model not found: " + id}}).dump(), "application/json");
            return;
        }

        models_reg["selected_model"] = id;
        save_registry(kModelsRegistryPath, models_reg);
        res.set_content(json({
            {"success", true},
            {"selected_model", id},
            {"note", "Selection saved. Restart stack to apply model change."}
        }).dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_backend_list(const httplib::Request& req, httplib::Response& res) {
    try {
        json backends_reg = load_backends_registry();
        save_registry(kBackendsRegistryPath, backends_reg);
        res.set_content(backends_reg.dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_backend_add(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = to_lower_copy(trim_copy(body.value("id", "")));
        const std::string type = trim_copy(body.value("type", "external"));
        const std::string entrypoint = trim_copy(body.value("entrypoint", ""));
        json formats = body.contains("formats") && body["formats"].is_array()
            ? body["formats"]
            : json::array({"openvino"});

        if (id.empty() || entrypoint.empty()) {
            res.status = 400;
            res.set_content(R"({"error":"id and entrypoint are required"})", "application/json");
            return;
        }

        json backends_reg = load_backends_registry();
        bool updated = false;
        for (auto& item : backends_reg["backends"]) {
            if (item.value("id", "") == id) {
                item["type"] = type;
                item["entrypoint"] = entrypoint;
                item["formats"] = formats;
                item["status"] = "ready";
                updated = true;
                break;
            }
        }
        if (!updated) {
            backends_reg["backends"].push_back({
                {"id", id},
                {"type", type},
                {"entrypoint", entrypoint},
                {"formats", formats},
                {"status", "ready"}
            });
        }

        save_registry(kBackendsRegistryPath, backends_reg);
        res.set_content(json({
            {"success", true},
            {"updated", updated},
            {"id", id}
        }).dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

void RestAPIServer::handle_cli_backend_select(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body);
        const std::string id = to_lower_copy(trim_copy(body.value("id", "")));
        if (id.empty()) {
            res.status = 400;
            res.set_content(R"({"error":"id is required"})", "application/json");
            return;
        }

        json backends_reg = load_backends_registry();
        if (!has_registry_item(backends_reg["backends"], id)) {
            res.status = 404;
            res.set_content(json({{"error", "Backend not found: " + id}}).dump(), "application/json");
            return;
        }

        backends_reg["selected_backend"] = id;
        save_registry(kBackendsRegistryPath, backends_reg);
        res.set_content(json({
            {"success", true},
            {"selected_backend", id},
            {"note", "Selection saved. Restart stack to apply backend change."}
        }).dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(json({{"error", e.what()}}).dump(), "application/json");
    }
}

