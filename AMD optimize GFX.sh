#!/usr/bin/env bash

# Environment variables for AMD and DXVK
__GL_SHADER_DISK_CACHE_APP_NAME=steamapp_shader_cache
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_SYNC_TO_VBLANK=0
AMD_VK_PIPELINE_CACHE_FILENAME=steamapp_shader_cache
AMD_VK_USE_PIPELINE_CACHE=1
DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1
DXVK_ASYNC="1"
DXVK_CONFIG="${DXVK_STATE_CACHE_PATH}/dxvk.conf"
DXVK_HUD="fps,frametimes,submissions,compiler"
DXVK_LOG_LEVEL="info"
DXVK_LOG_PATH="${DXVK_STATE_CACHE_PATH}/logs"
DXVK_STATE_CACHE_PATH="${HOME}/.local/share/dxvk"
ENABLE_VK_LAYER_VALVE_steam_fossilize_1=1
ENABLE_VK_LAYER_VALVE_steam_overlay_1=1
GAMESCOPE_DISABLE_ASYNC_FLIPS=1
GAMESCOPE_LIMITER_FILE=/tmp/gamescope-limiter.ZMUpAYuV
GAMESCOPE_NV12_COLORSPACE=k_EStreamColorspace_BT601
MESA_DISK_CACHE_SINGLE_FILE=1
mesa_glthread=true
MESA_SHADER_CACHE_MAX_SIZE=5G
SteamStreamingHardwareEncodingAMD=1
SteamStreamingHardwareEncodingIntel=0
vblank_mode=0

# Create DXVK directories if missing
mkdir -p "$DXVK_STATE_CACHE_PATH" "$DXVK_LOG_PATH"

# Write out a new DXVK config file
cat > "$DXVK_CONFIG" <<EOL
dxvk.numCompilerThreads = 12
dxvk.hud = fps,frametimes,submissions,compiler
dxvk.enableDebugUtils = True
dxgi.syncInterval = 0
dxgi.numBackBuffers = 0
dxgi.maxSharedMemory = 114441
dxgi.maxFrameRate = 60
dxgi.maxFrameLatency = 2
dxgi.maxDeviceMemory = 16384
dxgi.hideNvkGpu = True
dxgi.hideNvidiaGpu = True
dxgi.hideIntelGpu = True
dxgi.hideAmdGpu = False
dxgi.deferSurfaceCreation = True
dxgi.customDeviceDesc = 'RX 7800 XT'
d3d11.forceSampleRateShading = True
d3d11.cachedDynamicResources = 'a'
dxvk.maxChunkSize = 1024
dxvk.enableGraphicsPipelineLibrary = Auto
EOL

 echo profile_peak | sudo tee /sys/class/drm/card0/device/power_dpm_force_performance_level

AMD_DEBUG=lowlatencyenc
sudo setcap cap_sys_admin+ep
isolate game to 4 cores or 8 if CPU bound
enable huge pages
enabel large BAR
