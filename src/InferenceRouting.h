#pragma once

#include "RuntimeConfig.h"
#include "../OpenVINO/Backend/BackendPool.h"
#include "../OpenVINO/Scheduler/IScheduler.h"
#include <string>

// Whitespace-based token estimate (matches interactive CLI path in main.cpp).
int64_t estimate_prompt_tokens(const std::string& prompt);

// Pick prefill/decode devices when split-prefill is enabled but not configured yet.
void ensure_split_prefill_device_names(
    RuntimeConfig* config,
    IScheduler* scheduler,
    BackendPool* pool
);

// Hot-load a second device when split-prefill is turned on at runtime.
bool ensure_split_prefill_devices_loaded(
    BackendPool* pool,
    RuntimeConfig* config,
    IScheduler* scheduler,
    std::string& error_out
);

// Apply context-routing and split-prefill before generation. Returns true if active device changed.
bool apply_inference_routing(
    BackendPool* pool,
    RuntimeConfig* config,
    IScheduler* scheduler,
    const std::string& prompt
);
