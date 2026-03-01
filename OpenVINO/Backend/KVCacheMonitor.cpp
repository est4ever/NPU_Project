#include "KVCacheMonitor.h"
#include <iostream>
#include <iomanip>
#include <filesystem>
#include <psapi.h>

KVCacheMonitor::KVCacheMonitor() 
    : disk_paging_enabled_(false), paging_dir_("./kv_cache_paging") {
}

KVCacheMonitor::MemoryStats KVCacheMonitor::get_memory_stats() const {
    MemoryStats stats = {};
    query_windows_memory(stats);
    return stats;
}

void KVCacheMonitor::query_windows_memory(MemoryStats& stats) const {
    MEMORYSTATUSEX mem_status;
    mem_status.dwLength = sizeof(mem_status);
    
    if (GlobalMemoryStatusEx(&mem_status)) {
        stats.total_ram_mb = static_cast<size_t>(mem_status.ullTotalPhys / (1024 * 1024));
        stats.available_ram_mb = static_cast<size_t>(mem_status.ullAvailPhys / (1024 * 1024));
        stats.used_ram_mb = stats.total_ram_mb - stats.available_ram_mb;
        stats.usage_percent = static_cast<float>(mem_status.dwMemoryLoad) / 100.0f;
    }
    
    // Note: VRAM tracking requires vendor-specific APIs (NVML for NVIDIA, etc.)
    // For now, we'll set VRAM values to 0 (can be extended later)
    stats.total_vram_mb = 0;
    stats.available_vram_mb = 0;
    stats.used_vram_mb = 0;
    stats.vram_usage_percent = 0.0f;
}

bool KVCacheMonitor::is_memory_critical(float threshold) const {
    auto stats = get_memory_stats();
    return stats.usage_percent >= threshold;
}

size_t KVCacheMonitor::estimate_kv_cache_size(size_t context_tokens, size_t num_layers, size_t hidden_dim) {
    // Rough estimation formula for KV-cache size:
    // For each layer: 2 (K and V) * context_length * hidden_dim * bytes_per_element
    // 
    // With INT8 quantization: 1 byte per element
    // Without quantization (FP16): 2 bytes per element
    
    const size_t BYTES_PER_ELEMENT_INT8 = 1;
    const size_t KV_HEADS = 2;  // Key and Value
    
    size_t size_per_layer = KV_HEADS * context_tokens * hidden_dim * BYTES_PER_ELEMENT_INT8;
    size_t total_size = size_per_layer * num_layers;
    
    // Convert to MB
    return total_size / (1024 * 1024);
}

void KVCacheMonitor::print_memory_status() const {
    auto stats = get_memory_stats();
    
    std::cout << "\n[KVCache Monitor] Memory Status:\n";
    std::cout << "  System RAM: " << stats.used_ram_mb << " / " << stats.total_ram_mb << " MB ";
    std::cout << "(" << std::fixed << std::setprecision(1) << (stats.usage_percent * 100) << "%)\n";
    
    if (stats.total_vram_mb > 0) {
        std::cout << "  VRAM: " << stats.used_vram_mb << " / " << stats.total_vram_mb << " MB ";
        std::cout << "(" << std::fixed << std::setprecision(1) << (stats.vram_usage_percent * 100) << "%)\n";
    }
    
    if (is_memory_critical(0.90f)) {
        std::cout << "  ⚠️  WARNING: Memory usage above 90%!\n";
        if (disk_paging_enabled_) {
            std::cout << "  ✅ INT8 KV-cache quantization is active (50-75% memory savings)\n";
        } else {
            std::cout << "  💡 Enable memory optimization with --optimize-memory for INT8 compression\n";
        }
    }
    
    std::cout << "\n";
}

void KVCacheMonitor::set_disk_paging_enabled(bool enabled, const std::string& paging_dir) {
    disk_paging_enabled_ = enabled;
    paging_dir_ = paging_dir;
    
    if (enabled) {
        std::cout << "[KVCache Monitor] Memory optimization ENABLED\n";
        std::cout << "[KVCache Monitor] INT8 quantization reduces cache size by 50-75%\n";
        std::cout << "[KVCache Monitor] Monitoring memory usage (warning at 90% threshold)\n";
    } else {
        std::cout << "[KVCache Monitor] Memory optimization DISABLED\n";
    }
}
