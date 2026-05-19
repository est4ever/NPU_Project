#pragma once

#include <httplib.h>
#include <string>

namespace acoulm::security {

// Listen address (default 127.0.0.1). Set ACOULM_BIND_HOST=0.0.0.0 only on trusted networks.
std::string bind_host();

// Non-empty when ACOULM_API_TOKEN is set.
std::string api_token();

bool is_exposed_bind();

bool is_loopback_client(const httplib::Request& req);

bool bearer_token_valid(const httplib::Request& req);

// True if request may use control-plane APIs (CLI routes, model/backend changes).
bool control_plane_authorized(const httplib::Request& req);

// True if request may call chat completions.
bool chat_authorized(const httplib::Request& req);

void apply_cors_headers(const httplib::Request& req, httplib::Response& res);

// OPTIONS + auth gate. Returns true if response is complete (caller should stop).
bool handle_preflight_and_auth(const httplib::Request& req, httplib::Response& res);

void warn_if_insecure_startup();

}  // namespace acoulm::security
