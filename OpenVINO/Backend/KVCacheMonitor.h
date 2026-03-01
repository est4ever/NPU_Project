#pragma once
#include <cstddef>
#include <string>
#include <chrono>
#include <Windows.h>

// Memory monitoring and KV-cache management utility
class KVCacheMonitor {
public:
    struct MemoryStats {
        size_t total_ram_mb;
        size_t available_ram_mb;
        size_t used_ram_mb;
        float usage_percent;
        
        // GPU memory (if available)
        size_t total_vram_mb;
        size_t available_vram_mb;
        size_t used_vram_mb;
        float vram_usage_percent;
    };
    
    KVCacheMonitor();
    
    // Get current system memory stats
    MemoryStats get_memory_stats() const;
    
    // Check if memory is above threshold (e.g., 90%)
    bool is_memory_critical(float threshold = 0.90f) const;
    
    // Estimate KV-cache size for a given context length
    static size_t estimate_kv_cache_size(size_t context_tokens, size_t num_layers = 32, size_t hidden_dim = 4096);
    
    // Print memory status
    void print_memory_status() const;
    
    // Enable/disable disk paging for KV-cache
    void set_disk_paging_enabled(bool enabled, const std::string& paging_dir = "./kv_cache_paging");
    
    bool is_disk_paging_enabled() const { return disk_paging_enabled_; }
    std::string get_paging_directory() const { return paging_dir_; }
    
private:
    bool disk_paging_enabled_;
    std::string paging_dir_;
    
    // Windows-specific memory query
    void query_windows_memory(MemoryStats& stats) const;
};
