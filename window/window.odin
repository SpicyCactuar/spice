package window

import "core:fmt"
import "core:log"
import "vendor:glfw"
import "vendor:vulkan"

Window :: struct {
	handle:        glfw.WindowHandle,
	title:         string,
	width, height: i32,
	instance:      vulkan.Instance,
	surface:       vulkan.SurfaceKHR,
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

	instance, surface, vulkan_initialized := init_vulkan(
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
			surface = surface,
		},
		true
}

// TODO: Specify return
init_vulkan :: proc(
	window: glfw.WindowHandle,
	application_name: cstring,
) -> (
	instance: vulkan.Instance,
	surface: vulkan.SurfaceKHR,
	ok: bool,
) {
	vulkan.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))

	application_info := vulkan.ApplicationInfo {
		sType            = vulkan.StructureType.APPLICATION_INFO,
		pNext            = nil,
		pApplicationName = application_name,
		apiVersion       = vulkan.MAKE_VERSION(1, 4, 0),
	}

	instance_extensions := glfw.GetRequiredInstanceExtensions()
	instance_extensions_count := cast(u32)len(instance_extensions)
	if (instance_extensions_count == 0) {
		log.error("no Vulkan extensions found, need at least 'VK_KHR_surface'")
		return
	}

	log.infof("Found %d Vulkan extension(s)", instance_extensions_count);
	for extension, _ in instance_extensions {
		log.infof("%s", extension);
	}

	instance_create_info := vulkan.InstanceCreateInfo {
		sType                   = vulkan.StructureType.INSTANCE_CREATE_INFO,
		pNext                   = nil,
		pApplicationInfo        = &application_info,
		enabledExtensionCount   = instance_extensions_count,
		ppEnabledExtensionNames = raw_data(instance_extensions),
		enabledLayerCount       = 0,
	}

	create_instance_result := vulkan.CreateInstance(&instance_create_info, nil, &instance)
	if (create_instance_result != vulkan.Result.SUCCESS) {
		log.errorf("Could not create Instance - Result: %v", create_instance_result)
		return
	}

	vulkan.load_proc_addresses(instance)

	physical_devices_count: u32
	vulkan.EnumeratePhysicalDevices(instance, &physical_devices_count, nil)
	if (physical_devices_count == 0) {
		log.error("No Vulkan capable GPU found")
		return
	}

	physical_devices := make([]vulkan.PhysicalDevice, physical_devices_count)
	defer delete(physical_devices)
	vulkan.EnumeratePhysicalDevices(instance, &physical_devices_count, raw_data(physical_devices))

	log.infof("Found %d physical device(s)", physical_devices_count)

	create_surface_result := glfw.CreateWindowSurface(instance, window, nil, &surface)
	if (create_surface_result != vulkan.Result.SUCCESS) {
		log.errorf("Could not create Vulkan surface - Result: %v", create_surface_result)
		return
	}

	return instance, surface, true
}

loop_until_close :: proc(window: Window) {
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

cleanup :: proc(window: Window) {
	log.info("Terminating Window")
	vulkan.DestroySurfaceKHR(window.instance, window.surface, nil);
	vulkan.DestroyInstance(window.instance, nil);
	glfw.DestroyWindow(window.handle)
	glfw.Terminate()
}
