#pragma once
#include "../OpenVINO/Backend/BackendPool.h"
#include "RuntimeConfig.h"
#include <string>
#include <memory>
#include <atomic>

class KVCacheMonitor;

// Forward declarations to avoid including httplib in header
namespace httplib {
    class Server;
    class Request;
    class Response;
}

class RestAPIServer {
public:
    RestAPIServer(BackendPool* pool, int port = 8080);
    RestAPIServer(BackendPool* pool, RuntimeConfig* config, int port = 8080);
    RestAPIServer(BackendPool* pool, RuntimeConfig* config, KVCacheMonitor* kv_monitor, int port = 8080);
    ~RestAPIServer();

    // Start the server (blocking call - run in separate thread)
    void start();
    
    // Stop the server gracefully
    void stop();
    
    // Check if server is running
    bool is_running() const;

private:
    BackendPool* backend_pool_;
    RuntimeConfig default_config_;
    RuntimeConfig* config_;
    KVCacheMonitor* kv_monitor_;
    std::unique_ptr<httplib::Server> server_;
    int port_;
    std::atomic<bool> running_;

    // Handler for /v1/chat/completions endpoint (pure chat only - no commands)
    void handle_chat_completions(const class httplib::Request& req, class httplib::Response& res);
    
    // Handler for /v1/models endpoint
    void handle_list_models(const class httplib::Request& req, class httplib::Response& res);
    
    // Health check endpoint
    void handle_health(const class httplib::Request& req, class httplib::Response& res);

    // ===== CLI Endpoints - For terminal control commands only =====
    
    // GET /v1/cli/status - Get all system status and configuration
    void handle_cli_status(const class httplib::Request& req, class httplib::Response& res);
    
    // POST /v1/cli/device/switch - Switch active device
    void handle_cli_device_switch(const class httplib::Request& req, class httplib::Response& res);
    
    // POST /v1/cli/policy - Set scheduling policy
    void handle_cli_policy(const class httplib::Request& req, class httplib::Response& res);
    
    // POST /v1/cli/feature/{feature} - Toggle features (json, split-prefill, etc.)
    void handle_cli_feature_toggle(const class httplib::Request& req, class httplib::Response& res);
    
    // POST /v1/cli/threshold - Set prefill token threshold
    void handle_cli_threshold(const class httplib::Request& req, class httplib::Response& res);
    
    // GET /v1/cli/metrics - Get metrics data
    void handle_cli_metrics(const class httplib::Request& req, class httplib::Response& res);

    // GET /v1/cli/model/list - List registered models and selected model
    void handle_cli_model_list(const class httplib::Request& req, class httplib::Response& res);

    // POST /v1/cli/model/import - Import/register a model
    void handle_cli_model_import(const class httplib::Request& req, class httplib::Response& res);

    // POST /v1/cli/model/select - Select active model (applies next restart)
    void handle_cli_model_select(const class httplib::Request& req, class httplib::Response& res);

    // GET /v1/cli/backend/list - List registered backends and selected backend
    void handle_cli_backend_list(const class httplib::Request& req, class httplib::Response& res);

    // POST /v1/cli/backend/add - Register a backend entry
    void handle_cli_backend_add(const class httplib::Request& req, class httplib::Response& res);

    // POST /v1/cli/backend/select - Select backend (applies next restart)
    void handle_cli_backend_select(const class httplib::Request& req, class httplib::Response& res);
};
