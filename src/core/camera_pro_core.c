/*
 * camera_pro_core.c — Version and error-string introspection.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

int32_t camera_pro_core_version(void) {
    return (CAMERA_PRO_CORE_VERSION_MAJOR << 16) |
           (CAMERA_PRO_CORE_VERSION_MINOR << 8)  |
           (CAMERA_PRO_CORE_VERSION_PATCH);
}

const char* camera_pro_core_version_string(void) {
    return "0.0.2";
}

const char* camera_pro_error_string(int32_t error) {
    switch ((camera_error_t)error) {
        case CAMERA_OK:                          return "OK";
        case CAMERA_ERROR_NOT_INITIALIZED:       return "Not initialized";
        case CAMERA_ERROR_ALREADY_INITIALIZED:   return "Already initialized";
        case CAMERA_ERROR_DEVICE_NOT_FOUND:      return "Device not found";
        case CAMERA_ERROR_DEVICE_IN_USE:         return "Device in use by another application";
        case CAMERA_ERROR_DEVICE_DISCONNECTED:   return "Device disconnected";
        case CAMERA_ERROR_PERMISSION_DENIED:     return "Camera permission denied";
        case CAMERA_ERROR_CONFIGURATION_FAILED:  return "Configuration failed";
        case CAMERA_ERROR_CAPTURE_FAILED:        return "Capture failed";
        case CAMERA_ERROR_FEATURE_NOT_SUPPORTED: return "Feature not supported on this device";
        case CAMERA_ERROR_INVALID_PARAMETER:     return "Invalid parameter";
        case CAMERA_ERROR_SESSION_INTERRUPTED:   return "Session interrupted";
        case CAMERA_ERROR_THERMAL_THROTTLE:      return "Thermal throttling";
        case CAMERA_ERROR_MEMORY_PRESSURE:       return "Memory pressure";
        case CAMERA_ERROR_SERVICE_FATAL:         return "Camera service crashed";
        case CAMERA_ERROR_TIMEOUT:               return "Operation timed out";
        case CAMERA_ERROR_OUT_OF_MEMORY:         return "Out of memory";
        case CAMERA_ERROR_UNKNOWN:               return "Unknown error";
        default:                                 return "Unrecognized error code";
    }
}
