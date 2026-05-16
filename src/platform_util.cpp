#include "platform_util.h"

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <psapi.h>
#else
#include <unistd.h>
#include <signal.h>
#endif

namespace acoulm {

int64_t process_id() {
#ifdef _WIN32
    return static_cast<int64_t>(GetCurrentProcessId());
#else
    return static_cast<int64_t>(getpid());
#endif
}

void set_env_var(const std::string& key, const std::string& value) {
#ifdef _WIN32
    _putenv_s(key.c_str(), value.c_str());
#else
    setenv(key.c_str(), value.c_str(), 1);
#endif
}

std::filesystem::path executable_directory() {
#ifdef _WIN32
    char exe_path[MAX_PATH]{};
    const DWORD len = GetModuleFileNameA(nullptr, exe_path, static_cast<DWORD>(sizeof(exe_path)));
    if (len > 0 && len < sizeof(exe_path)) {
        return std::filesystem::path(std::string(exe_path)).parent_path();
    }
#else
    std::error_code ec;
    const auto link = std::filesystem::read_symlink("/proc/self/exe", ec);
    if (!ec) {
        return link.parent_path();
    }
#endif
    return std::filesystem::current_path();
}

std::filesystem::path detect_project_root() {
    try {
        const std::filesystem::path exe_dir = executable_directory();
        std::vector<std::filesystem::path> candidates = {
            exe_dir,
            exe_dir.parent_path(),
            exe_dir.parent_path().parent_path()
        };
        for (const auto& candidate : candidates) {
            if (candidate.empty()) {
                continue;
            }
            std::error_code ec;
            if (std::filesystem::exists(candidate / "registry", ec) ||
                std::filesystem::exists(candidate / "run.ps1", ec) ||
                std::filesystem::exists(candidate / "run.sh", ec)) {
                return candidate;
            }
        }
    } catch (...) {
    }
    return std::filesystem::current_path();
}

std::optional<nlohmann::json> current_process_memory_json() {
    const auto to_mb = [](uint64_t bytes) -> int64_t {
        return static_cast<int64_t>(bytes / (1024ull * 1024ull));
    };

#ifdef _WIN32
    PROCESS_MEMORY_COUNTERS_EX pmc_ex{};
    if (GetProcessMemoryInfo(
            GetCurrentProcess(),
            reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc_ex),
            sizeof(pmc_ex))) {
        return nlohmann::json{
            {"pid", process_id()},
            {"working_set_mb", to_mb(pmc_ex.WorkingSetSize)},
            {"private_mb", to_mb(pmc_ex.PrivateUsage)},
            {"peak_working_set_mb", to_mb(pmc_ex.PeakWorkingSetSize)}
        };
    }
#else
    std::ifstream status("/proc/self/status");
    if (status.is_open()) {
        std::string line;
        uint64_t rss_kb = 0;
        uint64_t vm_peak_kb = 0;
        while (std::getline(status, line)) {
            if (line.rfind("VmRSS:", 0) == 0) {
                std::istringstream iss(line.substr(6));
                iss >> rss_kb;
            } else if (line.rfind("VmPeak:", 0) == 0) {
                std::istringstream iss(line.substr(7));
                iss >> vm_peak_kb;
            }
        }
        if (rss_kb > 0) {
            return nlohmann::json{
                {"pid", process_id()},
                {"working_set_mb", to_mb(rss_kb * 1024ull)},
                {"private_mb", to_mb(rss_kb * 1024ull)},
                {"peak_working_set_mb", to_mb(vm_peak_kb * 1024ull)}
            };
        }
    }
#endif
    return std::nullopt;
}

bool spawn_detached_script(
    const std::filesystem::path& working_dir,
    const std::filesystem::path& script_path) {
#ifdef _WIN32
    const std::string root = working_dir.string();
    const std::string script = script_path.string();
    const std::string cmd =
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::vector<char> cmdline(cmd.begin(), cmd.end());
    cmdline.push_back('\0');
    if (!CreateProcessA(
            nullptr,
            cmdline.data(),
            nullptr,
            nullptr,
            FALSE,
            0,
            nullptr,
            root.c_str(),
            &si,
            &pi)) {
        return false;
    }
    if (pi.hThread) {
        CloseHandle(pi.hThread);
    }
    if (pi.hProcess) {
        CloseHandle(pi.hProcess);
    }
    return true;
#else
    const std::string root = working_dir.string();
    const std::string script = script_path.string();
    std::string cmd = "cd \"" + root + "\" && nohup bash \"" + script + "\" >/dev/null 2>&1 &";
    return std::system(cmd.c_str()) == 0;
#endif
}

void exit_process(int code) {
#ifdef _WIN32
    ExitProcess(static_cast<UINT>(code));
#else
    _exit(code);
#endif
}

}  // namespace acoulm
