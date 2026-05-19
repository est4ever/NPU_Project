#include "ApiSecurity.hpp"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <string>

namespace acoulm::security {
namespace {

using json = nlohmann::json;

std::string trim_copy(std::string s) {
    auto not_space = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
    s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    return s;
}

std::string env_copy(const char* name) {
    if (!name) {
        return {};
    }
#ifdef _WIN32
    char* buf = nullptr;
    size_t len = 0;
    if (_dupenv_s(&buf, &len, name) != 0 || !buf) {
        return {};
    }
    std::string out(buf);
    free(buf);
    return trim_copy(out);
#else
    const char* v = std::getenv(name);
    return v ? trim_copy(v) : std::string{};
#endif
}

bool truthy_env(const char* name) {
    const std::string v = env_copy(name);
    if (v.empty()) {
        return false;
    }
    std::string lower = v;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return lower == "1" || lower == "true" || lower == "yes" || lower == "on";
}

std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return s;
}

}  // namespace

std::string bind_host() {
    std::string host = env_copy("ACOULM_BIND_HOST");
    if (host.empty()) {
        return "127.0.0.1";
    }
    return host;
}

std::string api_token() {
    return env_copy("ACOULM_API_TOKEN");
}

bool is_exposed_bind() {
    const std::string host = bind_host();
    return host != "127.0.0.1" && host != "localhost" && host != "::1";
}

bool is_loopback_client(const httplib::Request& req) {
    const std::string peer = req.remote_addr;
    return peer == "127.0.0.1" || peer == "::1" || peer == "localhost" || peer.empty();
}

bool bearer_token_valid(const httplib::Request& req) {
    const std::string expected = api_token();
    if (expected.empty()) {
        return true;
    }
    const std::string auth = req.get_header_value("Authorization");
    const std::string prefix = "Bearer ";
    if (auth.size() <= prefix.size()) {
        return false;
    }
    if (auth.compare(0, prefix.size(), prefix) != 0) {
        return false;
    }
    return trim_copy(auth.substr(prefix.size())) == expected;
}

bool control_plane_authorized(const httplib::Request& req) {
    if (!bearer_token_valid(req)) {
        return false;
    }
    if (is_loopback_client(req)) {
        return true;
    }
    return !api_token().empty();
}

bool chat_authorized(const httplib::Request& req) {
    if (!bearer_token_valid(req)) {
        return false;
    }
    if (is_loopback_client(req)) {
        return true;
    }
    const std::string cli = to_lower(req.get_header_value("x-npu-cli"));
    if (cli == "true") {
        return true;
    }
    const std::string panel = to_lower(req.get_header_value("x-acoulm-panel"));
    if (panel == "true") {
        return true;
    }
    return !api_token().empty();
}

void apply_cors_headers(const httplib::Request& req, httplib::Response& res) {
    if (truthy_env("ACOULM_INSECURE_CORS")) {
        res.set_header("Access-Control-Allow-Origin", "*");
    } else {
        const std::string origin = req.get_header_value("Origin");
        if (!origin.empty()) {
            const std::string o = origin;
            if (o.rfind("http://127.0.0.1:", 0) == 0 || o.rfind("http://localhost:", 0) == 0 ||
                o == "http://127.0.0.1" || o == "http://localhost") {
                res.set_header("Access-Control-Allow-Origin", origin);
                res.set_header("Vary", "Origin");
            }
        }
    }
    res.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.set_header("Access-Control-Allow-Headers",
                   "Content-Type, Authorization, x-npu-cli, x-acoulm-panel");
}

bool handle_preflight_and_auth(const httplib::Request& req, httplib::Response& res) {
    apply_cors_headers(req, res);

    if (req.method == "OPTIONS") {
        res.status = 204;
        return true;
    }

    const std::string& path = req.path;
    const bool is_health = path == "/health" || path == "/v1/health";
    const bool is_chat = path == "/v1/chat/completions";
    const bool is_cli = path.rfind("/v1/cli/", 0) == 0;

    if (!bearer_token_valid(req)) {
        res.status = 401;
        res.set_content(
            json{{"error",
                  {{"code", "unauthorized"},
                   {"message", "Missing or invalid Authorization Bearer token (set ACOULM_API_TOKEN)."}}}}
                .dump(),
            "application/json");
        return true;
    }

    if (is_health) {
        return false;
    }

    if (is_chat && !chat_authorized(req)) {
        res.status = 403;
        res.set_content(
            json{{"error",
                  {{"code", "forbidden"},
                   {"message",
                    "Chat is only allowed from this machine (localhost). Use SSH tunnel or set "
                    "ACOULM_API_TOKEN and send Authorization: Bearer <token>."}}}}
                .dump(),
            "application/json");
        return true;
    }

    if (is_cli && !control_plane_authorized(req)) {
        res.status = 403;
        res.set_content(
            json{{"error",
                  {{"code", "forbidden"},
                   {"message",
                    "Control API is localhost-only unless ACOULM_API_TOKEN is configured and sent "
                    "as Authorization: Bearer <token>."}}}}
                .dump(),
            "application/json");
        return true;
    }

    return false;
}

void warn_if_insecure_startup() {
    if (is_exposed_bind() && api_token().empty()) {
        std::cerr << "[Security] ERROR: ACOULM_BIND_HOST=" << bind_host()
                  << " but ACOULM_API_TOKEN is not set. Refusing to listen on non-localhost.\n"
                  << "[Security] Fix: export ACOULM_API_TOKEN=$(openssl rand -hex 32) or bind "
                     "127.0.0.1 and use SSH tunnel.\n";
        std::exit(1);
    }
    if (is_exposed_bind()) {
        std::cerr << "[Security] WARNING: API listening on " << bind_host()
                  << " with token auth. Do not expose this port to the public internet.\n";
    } else {
        std::cout << "[Security] API bound to " << bind_host()
                  << " (localhost only). Remote access: SSH tunnel (-L 8000:127.0.0.1:8000).\n";
    }
    if (truthy_env("ACOULM_INSECURE_CORS")) {
        std::cerr << "[Security] WARNING: ACOULM_INSECURE_CORS=1 allows any browser origin.\n";
    }
}

}  // namespace acoulm::security
