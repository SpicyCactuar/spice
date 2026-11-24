package vks

import "base:runtime"
import "core:log"
import vkb "libs:odin-vk-bootstrap"
import vk "vendor:vulkan"

@(disabled = !ODIN_DEBUG)
enable_validation :: proc(instance_builder: ^vkb.Instance_Builder) {
    debug_messenger_logger = context.logger
    vkb.instance_builder_enable_validation_layers(instance_builder)
    vkb.instance_builder_set_debug_callback(instance_builder, debug_messenger_callback)

    vkb.instance_builder_add_layer_setting(
        instance_builder,
        vk.LayerSettingEXT {
            pLayerName = "VK_LAYER_KHRONOS_validation",
            pSettingName = "validate_sync",
            type = .BOOL32,
            valueCount = 1,
            pValues = &layer_setting_true,
        },
    )

    when GPU_ASSISTED_VALIDATION {
        vkb.instance_builder_add_layer_setting(
            instance_builder,
            vk.LayerSettingEXT {
                pLayerName = "VK_LAYER_KHRONOS_validation",
                pSettingName = "gpuav_enable",
                type = .BOOL32,
                valueCount = 1,
                pValues = &layer_setting_true,
            },
        )
    }
}

@(disabled = !ODIN_DEBUG)
log_validation_status :: proc(instance: vkb.Instance) {
    log.info("Enabled Vulkan validation layers")
    if instance.vk_debug_messenger != 0 {
        log.info("Enabled Vulkan debug messenger")
    }
}

// Names a Vulkan object so validation messages and tools like RenderDoc show `name` next to
// its handle. Calls are removed in release builds, where VK_EXT_debug_utils isn't enabled.
//
// `handle` is the raw handle as a u64: `u64(handle)` for most handles, but
// `u64(uintptr(handle))` for the dispatchable ones (Device, Queue, CommandBuffer), which are pointers.
@(disabled = !ODIN_DEBUG)
set_debug_name :: proc(gpu_context: Gpu_Context, type: vk.ObjectType, handle: u64, name: cstring) {
    name_info := vk.DebugUtilsObjectNameInfoEXT {
        sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
        pNext        = nil,
        objectType   = type,
        objectHandle = handle,
        pObjectName  = name,
    }
    vk.SetDebugUtilsObjectNameEXT(gpu_context.device.vk_device, &name_info)
}

// Vulkan calls the debug callback without an Odin context, so the callback
// can't see the caller's `context.logger`. This keeps a copy for it to use.
@(private = "file")
debug_messenger_logger: log.Logger

// Forwards validation layer and debug utils messages to `log`, mapping Vulkan
// severity to the matching log level.
@(private = "file")
debug_messenger_callback :: proc "system" (
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: rawptr,
) -> b32 {
    context = runtime.default_context()
    context.logger = debug_messenger_logger

    level: log.Level
    switch {
    case .ERROR in message_severity:
        level = .Error
    case .WARNING in message_severity:
        level = .Warning
    case .INFO in message_severity:
        level = .Info
    case:
        level = .Debug
    }

    log.logf(level, "[Vulkan %v] %s", message_types, callback_data.pMessage)
    return false // Applications must return false here
}

// Layer settings point at their values, and vk-bootstrap only reads them later, in
// instance_builder_build. So the value must outlive enable_validation: keep it package-level.
@(private = "file")
layer_setting_true: b32 = true

// GPU-assisted validation: instruments shaders to catch bugs only visible on the GPU, like
// out-of-bounds descriptor indexing. Slow, so off by default; debug builds only.
// Turn on with -define:GPU_ASSISTED_VALIDATION=true
@(private = "file")
GPU_ASSISTED_VALIDATION :: #config(GPU_ASSISTED_VALIDATION, false)
