package window

import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Renderer :: struct {
	swapchain:                  vkb.Swapchain,
	swapchain_images:           []vk.Image,
	swapchain_image_views:      []vk.ImageView,
	command_pool:               vk.CommandPool,
	command_buffers:            [FRAMES_IN_FLIGHT]vk.CommandBuffer,
	fences:                     [FRAMES_IN_FLIGHT]vk.Fence,
	image_acquired_semaphores:  [FRAMES_IN_FLIGHT]vk.Semaphore,
	render_complete_semaphores: []vk.Semaphore,
	frame_index:                u32,
}

// TODO: Document
@(require_results)
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

	// Command buffers
	vk_device := vulkan_context.device.vk_device
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		pNext            = nil,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = vulkan_context.queue_family_index,
	}
	command_pool_result := vk.CreateCommandPool(
		vk_device,
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
		vk_device,
		&command_buffer_allocate_info,
		raw_data(&renderer.command_buffers),
	)
	if command_buffer_result != .SUCCESS {
		log.errorf("Failed to create command buffers: %v", command_buffer_result)
		return
	}

	// Synchronization
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		pNext = nil,
		flags = {.SIGNALED},
	}
	for &fence, index in renderer.fences {
		fence_create_result := vk.CreateFence(vk_device, &fence_create_info, nil, &fence)

		if fence_create_result != .SUCCESS {
			log.errorf("Failed to create fence #%d: %v", index, fence_create_result)
			return
		}
	}

	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = nil,
	}
	for &semaphore, index in renderer.image_acquired_semaphores {
		semaphore_create_result := vk.CreateSemaphore(
			vk_device,
			&semaphore_create_info,
			nil,
			&semaphore,
		)

		if semaphore_create_result != .SUCCESS {
			log.errorf(
				"Failed to create image acquired semaphore #%d: %v",
				index,
				semaphore_create_result,
			)
			return
		}
	}

	renderer.render_complete_semaphores = make([]vk.Semaphore, len(renderer.swapchain_images))
	for &semaphore, index in renderer.render_complete_semaphores {
		semaphore_create_result := vk.CreateSemaphore(
			vk_device,
			&semaphore_create_info,
			nil,
			&semaphore,
		)

		if semaphore_create_result != .SUCCESS {
			log.errorf(
				"Failed to create render complete semaphore #%d: %v",
				index,
				semaphore_create_result,
			)
			return
		}
	}

	return renderer, true
}

// TODO: Document
@(require_results)
draw_frame :: proc(renderer: ^Renderer, vulkan_context: Vulkan_Context) -> (ok: bool) {
	vk_device := vulkan_context.device.vk_device

	image_index, command_buffer, frame_ready := prepare_frame(renderer, vk_device)
	if !frame_ready {
		return
	}

	frame_rendered := render_frame(renderer, image_index, command_buffer)
	if !frame_rendered {
		return
	}

	frame_submitted := submit_frame(renderer, vulkan_context.queue, image_index, command_buffer)
	if !frame_submitted {
		return
	}

	return true
}

// TODO: Document
@(private = "file")
@(require_results)
prepare_frame :: proc(
	renderer: ^Renderer,
	vk_device: vk.Device,
) -> (
	image_index: u32,
	command_buffer: vk.CommandBuffer,
	ok: bool,
) {
	frame := renderer.frame_index
	fence_wait_result := vk.WaitForFences(vk_device, 1, &renderer.fences[frame], true, max(u64))
	if fence_wait_result != .SUCCESS {
		log.errorf("Failed to wait for fence in frame %d: %v", frame, fence_wait_result)
		return
	}

	acquire_result := vk.AcquireNextImageKHR(
		vk_device,
		renderer.swapchain.vk_swapchain,
		max(u64),
		renderer.image_acquired_semaphores[frame],
		0,
		&image_index,
	)

	#partial switch acquire_result {
	case .SUCCESS, .SUBOPTIMAL_KHR:
	// TODO: Usable. Handle SUBOPTIMAL.
	case .ERROR_OUT_OF_DATE_KHR:
		log.warn("Swapchain out of date")
		return
	case:
		log.errorf("Failed to acquire swapchain image in frame %d: %v", frame, acquire_result)
		return
	}

	reset_fences_result := vk.ResetFences(vk_device, 1, &renderer.fences[frame])
	if reset_fences_result != .SUCCESS {
		log.errorf("Failed to reset fence in frame %d: %v", frame, reset_fences_result)
		return
	}

	command_buffer = renderer.command_buffers[frame]
	reset_command_buffer_result := vk.ResetCommandBuffer(command_buffer, {})
	if reset_command_buffer_result != .SUCCESS {
		log.errorf(
			"Failed to reset command buffer in frame %d: %v",
			frame,
			reset_command_buffer_result,
		)
		return
	}

	command_buffer_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	command_buffer_begin_result := vk.BeginCommandBuffer(
		command_buffer,
		&command_buffer_begin_info,
	)
	if command_buffer_begin_result != .SUCCESS {
		log.errorf(
			"Failed to begin command buffer in frame %d: %v",
			frame,
			command_buffer_begin_result,
		)
		return
	}

	return image_index, command_buffer, true
}

@(private = "file")
@(require_results)
render_frame :: proc(
	renderer: ^Renderer,
	image_index: u32,
	command_buffer: vk.CommandBuffer,
) -> (
	ok: bool,
) {
	swapchain_image_subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}
	swapchain_image_transition_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask    = {},
		dstStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask    = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .ATTACHMENT_OPTIMAL,
		image            = renderer.swapchain_images[image_index],
		subresourceRange = swapchain_image_subresource_range,
	}
	swapchain_image_transition_dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &swapchain_image_transition_barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &swapchain_image_transition_dependency_info)

	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = renderer.swapchain_image_views[image_index],
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = CLEAR_COLOR,
	}
	render_area := vk.Rect2D {
		extent = renderer.swapchain.vk_extent,
	}
	rendering_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = render_area,
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment,
	}

	vk.CmdBeginRendering(command_buffer, &rendering_info)
	// TODO: Submit draw calls
	vk.CmdEndRendering(command_buffer)

	swapchain_image_present_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask    = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask     = {},
		dstAccessMask    = {},
		oldLayout        = .ATTACHMENT_OPTIMAL,
		newLayout        = .PRESENT_SRC_KHR,
		image            = renderer.swapchain_images[image_index],
		subresourceRange = swapchain_image_subresource_range,
	}
	swapchain_image_present_dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &swapchain_image_present_barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &swapchain_image_present_dependency_info)

	end_command_buffer_result := vk.EndCommandBuffer(command_buffer)
	if end_command_buffer_result != .SUCCESS {
		log.errorf(
			"Failed to end command buffer in frame %d: %v",
			renderer.frame_index,
			end_command_buffer_result,
		)
		return
	}

	return true
}

// Submits the frame's commands. Drawing waits for the image to be acquired, and completion
// signals the image's render complete semaphore (for presenting) and the frame's fence.
@(private = "file")
@(require_results)
submit_frame :: proc(
	renderer: ^Renderer,
	queue: vk.Queue,
	image_index: u32,
	command_buffer: vk.CommandBuffer,
) -> (
	ok: bool,
) {
	frame := renderer.frame_index

	wait_semaphore_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = renderer.image_acquired_semaphores[frame],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_semaphore_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = renderer.render_complete_semaphores[image_index],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	command_buffer_submit_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait_semaphore_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_buffer_submit_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_semaphore_info,
	}

	submit_result := vk.QueueSubmit2(queue, 1, &submit_info, renderer.fences[frame])
	if submit_result != .SUCCESS {
		log.errorf("Failed to submit frame %d: %v", frame, submit_result)
		return
	}

	return true
}

destroy_renderer :: proc(renderer: ^Renderer, vulkan_context: Vulkan_Context) {
	log.info("Destroying Renderer")
	// Device needs to be idle to destroy resources
	vk_device := vulkan_context.device.vk_device
	vk.DeviceWaitIdle(vk_device)

	for semaphore in renderer.render_complete_semaphores {
		vk.DestroySemaphore(vk_device, semaphore, nil)
	}
	delete(renderer.render_complete_semaphores)
	for semaphore in renderer.image_acquired_semaphores {
		vk.DestroySemaphore(vk_device, semaphore, nil)
	}
	for fence in renderer.fences {
		vk.DestroyFence(vk_device, fence, nil)
	}
	if renderer.command_pool != 0 {
		vk.DestroyCommandPool(vk_device, renderer.command_pool, nil)
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

@(private = "file")
CLEAR_COLOR := vk.ClearValue {
	color = {float32 = {0.1, 0.2, 0.4, 1.0}},
}
