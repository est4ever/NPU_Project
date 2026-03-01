#pragma once
#include "../OpenVINO/Backend/BackendPool.h"
#include <string>
#include <memory>
#include <atomic>

// Forward declarations to avoid including httplib in header
namespace httplib {
    class Server;
    class Request;
    class Response;
}

class RestAPIServer {
public:
    RestAPIServer(BackendPool* pool, int port = 8080);
    ~RestAPIServer();

    // Start the server (blocking call - run in separate thread)
    void start();
    
    // Stop the server gracefully
    void stop();
    
    // Check if server is running
    bool is_running() const;

private:
    BackendPool* backend_pool_;
    std::unique_ptr<httplib::Server> server_;
    int port_;
    std::atomic<bool> running_;

    // Handler for /v1/chat/completions endpoint
    void handle_chat_completions(const class httplib::Request& req, class httplib::Response& res);
    
    // Handler for /v1/models endpoint
    void handle_list_models(const class httplib::Request& req, class httplib::Response& res);
    
    // Health check endpoint
    void handle_health(const class httplib::Request& req, class httplib::Response& res);
};
