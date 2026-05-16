#include "InferenceRouting.h"
#include "../OpenVINO/Scheduler/OpenVINOScheduler.h"
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <set>

namespace {

bool routing_verbose() {
    const char* v = std::getenv("ACOULM_VERBOSE");
    return v && v[0] == '1';
}

bool is_device_available(const std::vector<std::string>& available, const std::string& device) {
    return std::find(available.begin(), available.end(), device) != available.end();
}

bool try_activate_device(BackendPool* pool, const std::string& device) {
    if (!pool || device.empty()) {
        return false;
    }
    for (const auto& loaded : pool->get_loaded_devices()) {
        if (loaded == device) {
            pool->set_active_device(device);
            return true;
        }
    }
    return false;
}

} // namespace

int64_t estimate_prompt_tokens(const std::string& prompt) {
    int64_t count = 0;
    bool in_token = false;
    for (unsigned char c : prompt) {
        if (std::isspace(c)) {
            if (in_token) {
                ++count;
                in_token = false;
            }
        } else {
            in_token = true;
        }
    }
    if (in_token) {
        ++count;
    }
    return count;
}

void ensure_split_prefill_device_names(
    RuntimeConfig* config,
    IScheduler* scheduler,
    BackendPool* pool
) {
    if (!config || !scheduler) {
        return;
    }

    const auto available = scheduler->discover_devices();
    const auto loaded = pool ? pool->get_loaded_devices() : std::vector<std::string>{};

    std::string prefill = config->prefill_device;
    std::string decode = config->decode_device;

    if (!is_device_available(available, prefill) && !loaded.empty()) {
        prefill = is_device_available(available, "GPU") ? "GPU"
            : (is_device_available(available, "CPU") ? "CPU" : loaded.front());
    }
    if (!is_device_available(available, decode) && !loaded.empty()) {
        decode = is_device_available(available, "NPU") ? "NPU"
            : (is_device_available(available, "GPU") ? "GPU" : loaded.front());
    }
    if (prefill == decode && is_device_available(available, "GPU") && is_device_available(available, "NPU")) {
        prefill = "GPU";
        decode = "NPU";
    }

    config->prefill_device = prefill;
    config->decode_device = decode;
}

bool ensure_split_prefill_devices_loaded(
    BackendPool* pool,
    RuntimeConfig* config,
    IScheduler* scheduler,
    std::string& error_out
) {
    if (!pool || !config) {
        error_out = "backend pool or config unavailable";
        return false;
    }

    const char* allow = std::getenv("ACOULM_ALLOW_MULTI_DEVICE");
    if (!allow || std::string(allow) != "1") {
        const auto already = pool->get_loaded_devices();
        if (already.size() >= 1) {
            error_out =
                "split-prefill needs a second device load; disabled by default to avoid duplicate model RAM. "
                "Set ACOULM_ALLOW_MULTI_DEVICE=1 and restart, or use a single device (acoulm cpu / --device CPU).";
            return false;
        }
    }

    ensure_split_prefill_device_names(config, scheduler, pool);

    std::set<std::string> need;
    need.insert(config->prefill_device);
    need.insert(config->decode_device);

    for (const auto& device : need) {
        bool already = false;
        for (const auto& loaded : pool->get_loaded_devices()) {
            if (loaded == device) {
                already = true;
                break;
            }
        }
        if (already) {
            continue;
        }
        if (!pool->load_device(device, error_out)) {
            return false;
        }
    }
    return pool->get_loaded_devices().size() >= 2;
}

bool apply_inference_routing(
    BackendPool* pool,
    RuntimeConfig* config,
    IScheduler* scheduler,
    const std::string& prompt
) {
    if (!pool || !config) {
        return false;
    }

    const auto loaded = pool->get_loaded_devices();
    const bool want_context = config->get_context_routing() && scheduler && loaded.size() > 1;
    const bool want_split = config->get_split_prefill() && loaded.size() >= 2;
    if (!want_context && !want_split) {
        return false;
    }

    const std::string previous = pool->get_active_device();

    if (want_context) {
        const size_t estimated_tokens = OpenVINOScheduler::estimate_token_count(prompt);
        const std::string target = scheduler->get_device_for_context(
            estimated_tokens,
            config->get_policy()
        );
        if (!try_activate_device(pool, target) && routing_verbose()) {
            std::cout << "[Routing] Context route target " << target
                      << " is not loaded; keeping " << pool->get_active_device() << "\n";
        }
    }

    if (want_split) {
        const int64_t prompt_tokens = static_cast<int64_t>(
            OpenVINOScheduler::estimate_token_count(prompt)
        );
        bool use_prefill = config->get_use_prefill_device();
        const int high = config->get_prefill_threshold_high();
        const int low = config->get_prefill_threshold_low();

        if (!use_prefill && prompt_tokens >= high) {
            use_prefill = true;
        } else if (use_prefill && prompt_tokens <= low) {
            use_prefill = false;
        }
        config->set_use_prefill_device(use_prefill);

        const std::string& target = use_prefill ? config->prefill_device : config->decode_device;
        if (!try_activate_device(pool, target) && routing_verbose()) {
            std::cout << "[Routing] Split-prefill target " << target
                      << " is not loaded; keeping " << pool->get_active_device() << "\n";
        }
    }

    return pool->get_active_device() != previous;
}
