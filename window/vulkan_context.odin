package window

import "base:runtime"
import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Vulkan_Context :: struct {
	instance:        vkb.Instance,
	surface:         vk.SurfaceKHR,
	physical_device: vkb.Physical_Device,
	device:          vkb.Device,
}

create_context :: proc(
	instance_extensions: []string,
	window: glfw.WindowHandle,
) -> (
	vulkan_context: Vulkan_Context,
	ok: bool,
) {
	defer if !ok {
		destroy(&vulkan_context)
	}

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

	instance_error := vkb.instance_builder_build(&instance_builder, &vulkan_context.instance)
	if instance_error != nil {
		log.errorf("Failed to build Vulkan instance: %v", instance_error)
		return
	}

	when ODIN_DEBUG {
		log.info("Enabled Vulkan validation layers")
		if vulkan_context.instance.vk_debug_messenger != 0 {
			log.info("Enabled Vulkan debug messenger")
		}
	}

	create_surface_result := glfw.CreateWindowSurface(
		vulkan_context.instance.vk_instance,
		window,
		nil,
		&vulkan_context.surface,
	)
	if create_surface_result != vk.Result.SUCCESS {
		log.errorf("Failed to create Vulkan surface - Result: %v", create_surface_result)
		return
	}

	physical_device_selector: vkb.Physical_Device_Selector
	vkb.physical_device_selector_init(&physical_device_selector, vulkan_context.instance)
	defer vkb.physical_device_selector_uninit(&physical_device_selector)

	vkb.physical_device_selector_set_surface(&physical_device_selector, vulkan_context.surface)
	vkb.physical_device_selector_set_minimum_version(&physical_device_selector, VULKAN_VERSION)

	physical_device_error := vkb.physical_device_selector_select(
		&physical_device_selector,
		&vulkan_context.physical_device,
	)
	if physical_device_error != nil {
		log.errorf("Failed to select Vulkan physical device: %v", physical_device_error)
		return
	}

	log.infof("Selected physical device: %s", vulkan_context.physical_device.name)

	device_builder: vkb.Device_Builder
	vkb.device_builder_init(&device_builder)
	defer vkb.device_builder_uninit(&device_builder)
	device_builder_error := vkb.device_builder_build(
		&device_builder,
		&vulkan_context.physical_device,
		&vulkan_context.device,
	)
	if device_builder_error != nil {
		log.errorf("Failed to build Vulkan logical device: %v", device_builder_error)
		return
	}

	return vulkan_context, true
}

destroy_context :: proc(vulkan_context: ^Vulkan_Context) {
	log.info("Destroying Vulkan Context")
	if vulkan_context.device.vk_device != nil {
		vkb.destroy_device(&vulkan_context.device)
	}
	if vulkan_context.physical_device.vk_physical_device != nil {
		// In Vulkan you don't need to destroy a physical_device, but here you need
		// to free some resources when the physical_device was created.
		vkb.destroy_physical_device(&vulkan_context.physical_device)
	}
	if vulkan_context.surface != 0 {
		vkb.destroy_surface(&vulkan_context.instance, vulkan_context.surface)
	}
	if vulkan_context.instance.vk_instance != nil {
		vkb.destroy_instance(&vulkan_context.instance)
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
