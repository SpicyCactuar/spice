package window

import "core:fmt"
import "core:log"
import "core:slice"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Window :: struct {
	handle:          glfw.WindowHandle,
	title:           string,
	width, height:   i32,
	instance:        vkb.Instance,
	physical_device: vkb.Physical_Device,
}

create_window :: proc(width, height: i32, title: string) -> (window: Window, ok: bool) {
	if !glfw.Init() {
		log.error("Failed to initialize GLFW")
		return
	}

	if glfw.VulkanSupported() != glfw.TRUE {
		log.error("GLFW does not support Vulkan")
		return
	}

	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	title_c := fmt.ctprintf(title)
	window_handle := glfw.CreateWindow(width, height, title_c, nil, nil)
	if window_handle == nil {
		log.error("Could not create GLFW window")
		glfw.Terminate()
		return
	}

	instance, physical_device, vulkan_initialized := init_vulkan(
		window = window_handle,
		application_name = title_c,
	)

	if !vulkan_initialized {
		log.errorf("Vulkan failed to initialize")
		return
	}

	return Window {
			handle = window_handle,
			title = title,
			width = width,
			height = height,
			instance = instance,
			physical_device = physical_device,
		},
		true
}

init_vulkan :: proc(
	window: glfw.WindowHandle,
	application_name: cstring,
) -> (
	instance: vkb.Instance,
	physical_device: vkb.Physical_Device,
	ok: bool,
) {
	instance_builder: vkb.Instance_Builder
	vkb.instance_builder_init(&instance_builder)
	defer vkb.instance_builder_uninit(&instance_builder)

	instance_extensions := glfw.GetRequiredInstanceExtensions()
	if len(instance_extensions) == 0 {
		log.error("no Vulkan extensions found, need at least 'VK_KHR_surface'")
		return
	}

	log.infof("Found %d Vulkan extension(s)", len(instance_extensions))
	extension_names, _ := slice.mapper(instance_extensions, proc(extension_c: cstring) -> string {
		return string(extension_c)
	})
	defer delete(extension_names)
	for extension, _ in extension_names {
		log.info(extension)
	}
	vkb.instance_builder_enable_extensions(&instance_builder, extension_names)
	vkb.instance_builder_require_api_version(&instance_builder, VULKAN_VERSION)

	when ODIN_DEBUG {
		vkb.instance_builder_enable_validation_layers(&instance_builder)
		vkb.instance_builder_use_default_debug_messenger(&instance_builder)
	}

	instance_error := vkb.instance_builder_build(&instance_builder, &instance)
	if instance_error != nil {
		log.errorf("Failed to build Vulkan instance: %v", instance_error)
		return
	}

	surface: vk.SurfaceKHR
	create_surface_result := glfw.CreateWindowSurface(instance.vk_instance, window, nil, &surface)
	if (create_surface_result != vk.Result.SUCCESS) {
		vkb.destroy_instance(&instance)
		log.errorf("Failed to create Vulkan surface - Result: %v", create_surface_result)
		return
	}

	physical_device_selector: vkb.Physical_Device_Selector
	vkb.physical_device_selector_init(&physical_device_selector, instance)
	defer vkb.physical_device_selector_uninit(&physical_device_selector)

	vkb.physical_device_selector_set_surface(&physical_device_selector, surface)
	vkb.physical_device_selector_set_minimum_version(&physical_device_selector, VULKAN_VERSION)

	physical_device_error := vkb.physical_device_selector_select(
		&physical_device_selector,
		&physical_device,
	)
	if physical_device_error != nil {
		vkb.destroy_surface(&instance, surface)
		vkb.destroy_instance(&instance)
		log.errorf("Failed to select Vulkan physical device: %v", physical_device_error)
		return
	}

	return instance, physical_device, true
}

loop_until_close :: proc(window: Window) {
	log.info("Looping until window is closed")
	glfw.SetKeyCallback(window.handle, close_on_escape_pressed)

	for !glfw.WindowShouldClose(window.handle) {
		glfw.PollEvents()
	}
}

close_on_escape_pressed :: proc "c" (
	window: glfw.WindowHandle,
	key: i32,
	scancode: i32,
	action: i32,
	mods: i32,
) {
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		glfw.SetWindowShouldClose(window, true)
	}
}

cleanup :: proc(window: ^Window) {
	log.info("Terminating Window")
	vkb.destroy_surface(&window.instance, window.physical_device.vk_surface)
	// In Vulkan you don't need to destroy a physical physical_device, but here you need
	// to free some resources when the physical physical_device was created.
	vkb.destroy_physical_device(&window.physical_device)
	vkb.destroy_instance(&window.instance)
	glfw.DestroyWindow(window.handle)
	glfw.Terminate()
}

VULKAN_VERSION := cast(u32)vk.API_VERSION_1_4
