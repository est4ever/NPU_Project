#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

#include <nlohmann/json.hpp>

namespace acoulm {

int64_t process_id();
void set_env_var(const std::string& key, const std::string& value);
std::filesystem::path executable_directory();
std::filesystem::path detect_project_root();
std::optional<nlohmann::json> current_process_memory_json();
bool spawn_detached_script(const std::filesystem::path& working_dir, const std::filesystem::path& script_path);
void exit_process(int code);

}  // namespace acoulm
