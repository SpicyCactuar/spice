package vks

import "base:runtime"
import "core:log"
import vkb "libs:odin-vk-bootstrap"
import vma "libs:odin-vma"
import "vendor:glfw"
import vk "vendor:vulkan"

Gpu_Context :: struct {
    instance:           vkb.Instance,
    surface:            vk.SurfaceKHR,
    physical_device:    vkb.Physical_Device,
    device:             vkb.Device,
    vma_allocator:      vma.Allocator,
    queue_family_index: u32,
    queue:              vk.Queue,
}

@(require_results)
create_gpu_context :: proc(
    instance_extensions: []string,
    window: glfw.WindowHandle,
) -> (
    gpu_context: Gpu_Context,
    ok: bool,
) {
    defer if !ok {
        destroy_gpu_context(&gpu_context)
    }

    // Instance
    instance_builder: vkb.Instance_Builder
    vkb.instance_builder_init(&instance_builder)
    defer vkb.instance_builder_uninit(&instance_builder)

    vkb.instance_builder_enable_extensions(&instance_builder, instance_extensions)
    vkb.instance_builder_require_api_version(&instance_builder, VULKAN_VERSION)

    when ODIN_DEBUG {
        debug_messenger_logger = context.logger
        vkb.instance_builder_enable_validation_layers(&instance_builder)
        vkb.instance_builder_set_debug_callback(&instance_builder, debug_messenger_callback)
    }

    check_success(
        vkb.instance_builder_build(&instance_builder, &gpu_context.instance),
        "Failed to build Vulkan instance",
    ) or_return

    when ODIN_DEBUG {
        log.info("Enabled Vulkan validation layers")
        if gpu_context.instance.vk_debug_messenger != 0 {
            log.info("Enabled Vulkan debug messenger")
        }
    }

    // Surface
    check_success(
        glfw.CreateWindowSurface(
            gpu_context.instance.vk_instance,
            window,
            nil,
            &gpu_context.surface,
        ),
        "Failed to create Vulkan surface",
    ) or_return

    // Device
    physical_device_selector: vkb.Physical_Device_Selector
    vkb.physical_device_selector_init(&physical_device_selector, gpu_context.instance)
    defer vkb.physical_device_selector_uninit(&physical_device_selector)

    vkb.physical_device_selector_set_surface(&physical_device_selector, gpu_context.surface)
    vkb.physical_device_selector_set_minimum_version(&physical_device_selector, VULKAN_VERSION)

    // Required features are also enabled on the logical device by vkb.
    vkb.physical_device_selector_set_required_features(
        &physical_device_selector,
        {samplerAnisotropy = true},
    )
    vkb.physical_device_selector_set_required_features_12(
        &physical_device_selector,
        {
            descriptorIndexing = true,
            shaderSampledImageArrayNonUniformIndexing = true,
            descriptorBindingVariableDescriptorCount = true,
            runtimeDescriptorArray = true,
            bufferDeviceAddress = true,
        },
    )
    vkb.physical_device_selector_set_required_features_13(
        &physical_device_selector,
        {synchronization2 = true, dynamicRendering = true},
    )

    check_success(
        vkb.physical_device_selector_select(
            &physical_device_selector,
            &gpu_context.physical_device,
        ),
        "Failed to select Vulkan physical device",
    ) or_return

    log.infof("Selected physical device: %s", gpu_context.physical_device.name)

    device_builder: vkb.Device_Builder
    vkb.device_builder_init(&device_builder)
    defer vkb.device_builder_uninit(&device_builder)
    check_success(
        vkb.device_builder_build(
            &device_builder,
            &gpu_context.physical_device,
            &gpu_context.device,
        ),
        "Failed to build Vulkan logical device",
    ) or_return

    // VMA
    vma_vulkan_functions := vma.create_vulkan_functions()
    vma_allocator_create_info := vma.AllocatorCreateInfo {
        flags            = {.BUFFER_DEVICE_ADDRESS},
        physicalDevice   = gpu_context.physical_device.vk_physical_device,
        device           = gpu_context.device.vk_device,
        instance         = gpu_context.instance.vk_instance,
        pVulkanFunctions = &vma_vulkan_functions,
        vulkanApiVersion = VULKAN_VERSION,
    }
    check_success(
        vma.CreateAllocator(
            pCreateInfo = vma_allocator_create_info,
            pAllocator = &gpu_context.vma_allocator,
        ),
        "Failed to create VMA allocator",
    ) or_return

    // Queue
    graphics_index := check_success(
        vkb.device_get_queue_index(gpu_context.device, .Graphics),
        "Failed to find a graphics queue family",
    ) or_return
    present_index := check_success(
        vkb.device_get_queue_index(gpu_context.device, .Present),
        "Failed to find a present queue family",
    ) or_return
    if graphics_index != present_index {
        log.errorf(
            "Graphics (family %d) and present (family %d) are on different queue families, which is not supported",
            graphics_index,
            present_index,
        )
        return
    }
    gpu_context.queue_family_index = graphics_index
    vk.GetDeviceQueue(gpu_context.device.vk_device, graphics_index, 0, &gpu_context.queue)
    log.infof(
        "Using queue 0 of family %d for graphics and present",
        gpu_context.queue_family_index,
    )

    return gpu_context, true
}

destroy_gpu_context :: proc(gpu_context: ^Gpu_Context) {
    log.info("Destroying Vulkan Context")
    if gpu_context.vma_allocator != nil {
        vma.DestroyAllocator(gpu_context.vma_allocator)
    }
    if gpu_context.device.vk_device != nil {
        vkb.destroy_device(&gpu_context.device)
    }
    if gpu_context.physical_device.vk_physical_device != nil {
        // In Vulkan you don't need to destroy a physical_device, but here you need
        // to free some resources when the physical_device was created.
        vkb.destroy_physical_device(&gpu_context.physical_device)
    }
    if gpu_context.surface != 0 {
        vkb.destroy_surface(&gpu_context.instance, gpu_context.surface)
    }
    if gpu_context.instance.vk_instance != nil {
        vkb.destroy_instance(&gpu_context.instance)
    }
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

@(private = "file")
VULKAN_VERSION := vk.MAKE_VERSION(1, 4, 0)
