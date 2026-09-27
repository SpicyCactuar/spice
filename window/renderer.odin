package window

import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Renderer :: struct {
	swapchain:             vkb.Swapchain,
	swapchain_images:      []vk.Image,
	swapchain_image_views: []vk.ImageView,
	command_pool:          vk.CommandPool,
	command_buffers:       [FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

create_renderer :: proc(
	vulkan_context: Vulkan_Context,
	window: glfw.WindowHandle,
) -> (
	renderer: Renderer,
	ok: bool,
) {
	defer if !ok {
		destroy(&renderer, vulkan_context)
	}

	// Surface capabilities
	surface_capabilities: vk.SurfaceCapabilitiesKHR
	surface_capabilities_result := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		vulkan_context.physical_device.vk_physical_device,
		vulkan_context.surface,
		&surface_capabilities,
	)
	if surface_capabilities_result != .SUCCESS {
		log.errorf("Failed to query surface capabilities: %v", surface_capabilities_result)
		return
	}

	// On Wayland the surface has no size of its own (0xFFFFFFFF), and the
	// swapchain decides it, so use the window's framebuffer size instead.
	swapchain_extent := surface_capabilities.currentExtent
	if surface_capabilities.currentExtent.width == max(u32) {
		width, height := glfw.GetFramebufferSize(window)
		swapchain_extent = {u32(width), u32(height)}
	}

	// Swapchain
	swapchain_builder: vkb.Swapchain_Builder
	vkb.swapchain_builder_init(
		&swapchain_builder,
		vulkan_context.physical_device,
		vulkan_context.device,
		vulkan_context.surface,
		vulkan_context.queue_family_index,
		vulkan_context.queue_family_index,
	)
	defer vkb.swapchain_builder_uninit(&swapchain_builder)

	vkb.swapchain_builder_set_desired_min_image_count(
		&swapchain_builder,
		surface_capabilities.minImageCount,
	)
	vkb.swapchain_builder_set_desired_format(
		&swapchain_builder,
		{format = .B8G8R8A8_SRGB, colorSpace = .SRGB_NONLINEAR},
	)
	vkb.swapchain_builder_set_desired_extent(
		&swapchain_builder,
		swapchain_extent.width,
		swapchain_extent.height,
	)
	vkb.swapchain_builder_set_image_array_layer_count(&swapchain_builder, 1)
	vkb.swapchain_builder_set_image_usage_flags(&swapchain_builder, {.COLOR_ATTACHMENT})
	vkb.swapchain_builder_set_pre_transform_flags(&swapchain_builder, {.IDENTITY})
	vkb.swapchain_builder_set_composite_alpha_flags(&swapchain_builder, {.OPAQUE})
	vkb.swapchain_builder_set_desired_present_mode(&swapchain_builder, .FIFO)

	swapchain_error := vkb.swapchain_builder_build(&swapchain_builder, &renderer.swapchain)
	if swapchain_error != nil {
		log.errorf("Failed to build swapchain: %v", swapchain_error)
		return
	}

	log.infof(
		"Built swapchain: %d image(s), %d x %d, %v, %v",
		renderer.swapchain.image_count,
		renderer.swapchain.vk_extent.width,
		renderer.swapchain.vk_extent.height,
		renderer.swapchain.vk_image_format,
		renderer.swapchain.vk_present_mode,
	)

	// Swapchain images and views
	images_error: vkb.Error
	renderer.swapchain_images, images_error = vkb.swapchain_get_images(renderer.swapchain)
	if images_error != nil {
		log.errorf("Failed to get swapchain images: %v", images_error)
		return
	}

	image_views_error: vkb.Error
	renderer.swapchain_image_views, image_views_error = vkb.swapchain_get_image_views(
		renderer.swapchain,
	)
	if image_views_error != nil {
		log.errorf("Failed to create swapchain image views: %v", image_views_error)
		return
	}

	// Command buffer
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		pNext            = nil,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = vulkan_context.queue_family_index,
	}
	command_pool_result := vk.CreateCommandPool(
		vulkan_context.device.vk_device,
		&command_pool_create_info,
		nil,
		&renderer.command_pool,
	)
	if command_pool_result != .SUCCESS {
		log.errorf("Failed to create command pool: %v", command_pool_result)
		return
	}

	command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		pNext              = nil,
		level              = .PRIMARY,
		commandBufferCount = FRAMES_IN_FLIGHT,
		commandPool        = renderer.command_pool,
	}
	command_buffer_result := vk.AllocateCommandBuffers(
		vulkan_context.device.vk_device,
		&command_buffer_allocate_info,
		raw_data(&renderer.command_buffers),
	)
	if command_buffer_result != .SUCCESS {
		log.errorf("Failed to create command buffers: %v", command_buffer_result)
		return
	}

	return renderer, true
}

destroy_renderer :: proc(renderer: ^Renderer, vulkan_context: Vulkan_Context) {
	log.info("Destroying Renderer")
	if renderer.command_pool != 0 {
		vk.DestroyCommandPool(vulkan_context.device.vk_device, renderer.command_pool, nil)
	}
	if renderer.swapchain_image_views != nil {
		vkb.swapchain_destroy_image_views(renderer.swapchain, renderer.swapchain_image_views)
		delete(renderer.swapchain_image_views)
	}
	// Swapchain images are owned by the swapchain, so only the slice is freed.
	delete(renderer.swapchain_images)
	if renderer.swapchain.vk_swapchain != 0 {
		vkb.destroy_swapchain(&renderer.swapchain)
	}
}

@(private = "file")
FRAMES_IN_FLIGHT :: u32(2)
