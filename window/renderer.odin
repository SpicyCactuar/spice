package window

import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Renderer :: struct {
	swapchain:                 Vulkan_Swapchain,
	swapchain_out_of_date:     bool,
	command_pool:              vk.CommandPool,
	command_buffers:           [FRAMES_IN_FLIGHT]vk.CommandBuffer,
	fences:                    [FRAMES_IN_FLIGHT]vk.Fence,
	image_acquired_semaphores: [FRAMES_IN_FLIGHT]vk.Semaphore,
	frame_index:               u32,
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

	// Swapchain
	swapchain_builder: vkb.Swapchain_Builder
	if !create_swapchain_builder(&swapchain_builder, vulkan_context, window) {
		return
	}
	defer vkb.swapchain_builder_uninit(&swapchain_builder)

	created_swapchain := create_swapchain(&renderer.swapchain, vulkan_context, &swapchain_builder)
	if !created_swapchain {
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

	return renderer, true
}

// TODO: Document
@(require_results)
draw_frame :: proc(
	renderer: ^Renderer,
	vulkan_context: Vulkan_Context,
	window: glfw.WindowHandle,
) -> (
	ok: bool,
) {
	framebuffer_width, framebuffer_height := glfw.GetFramebufferSize(window)
	width, height := u32(framebuffer_width), u32(framebuffer_height)
	if width == 0 || height == 0 {
		// Nothing to render, skip frame
		return true
	}

	extent := swapchain_extent(renderer.swapchain)
	if width != extent.width || height != extent.height {
		// Swapchain extents changed, needs recreation
		renderer.swapchain_out_of_date = true
	}

	vk_device := vulkan_context.device.vk_device
	if renderer.swapchain_out_of_date {
		if !recreate_swapchain(&renderer.swapchain, vulkan_context, window) {
			return
		}
		renderer.swapchain_out_of_date = false
	}

	image_index, command_buffer, frame_ready := prepare_frame(renderer, vk_device)
	if !frame_ready {
		return renderer.swapchain_out_of_date
	}

	frame_rendered := render_frame(renderer, image_index, command_buffer)
	if !frame_rendered {
		return
	}

	frame_submitted := submit_frame(renderer, vulkan_context.queue, image_index, command_buffer)
	if !frame_submitted {
		return
	}

	frame_presented := present_frame(renderer, vulkan_context.queue, &image_index)
	if !frame_presented {
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
		swapchain_handle(renderer.swapchain),
		max(u64),
		renderer.image_acquired_semaphores[frame],
		0,
		&image_index,
	)

	#partial switch acquire_result {
	case .SUCCESS:
	// continue
	case .SUBOPTIMAL_KHR:
		// An image was still acquired, so render and present it, then recreate on the next frame.
		renderer.swapchain_out_of_date = true
	case .ERROR_OUT_OF_DATE_KHR:
		renderer.swapchain_out_of_date = true
		log.warnf(
			"Swapchain needs recreating before preparing frame %d: %v",
			frame,
			acquire_result,
		)
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
		image            = renderer.swapchain.images[image_index],
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
		imageView   = renderer.swapchain.image_views[image_index],
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = CLEAR_COLOR,
	}
	render_area := vk.Rect2D {
		extent = swapchain_extent(renderer.swapchain),
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
		image            = renderer.swapchain.images[image_index],
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

// TODO: Document
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
		semaphore = renderer.swapchain.render_complete_semaphores[image_index],
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

// TODO: Document
@(private = "file")
@(require_results)
present_frame :: proc(renderer: ^Renderer, queue: vk.Queue, image_index: ^u32) -> (ok: bool) {
	frame := renderer.frame_index

	// `pSwapchains` needs a pointer, and a procedure's result can't be addressed.
	vk_swapchain := swapchain_handle(renderer.swapchain)
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &renderer.swapchain.render_complete_semaphores[image_index^],
		swapchainCount     = 1,
		pSwapchains        = &vk_swapchain,
		pImageIndices      = image_index,
	}
	present_result := vk.QueuePresentKHR(queue, &present_info)

	advance_frame(renderer)

	#partial switch present_result {
	case .SUCCESS:
	// continue
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		renderer.swapchain_out_of_date = true
		log.warnf(
			"Swapchain needs recreating after presenting frame %d: %v",
			frame,
			present_result,
		)
	case:
		log.errorf("Failed to present frame %d: %v", frame, present_result)
		return
	}

	return true
}

@(private = "file")
advance_frame :: proc(renderer: ^Renderer) {
	renderer.frame_index = (renderer.frame_index + 1) % FRAMES_IN_FLIGHT
}

destroy_renderer :: proc(renderer: ^Renderer, vulkan_context: Vulkan_Context) {
	log.info("Destroying Renderer")
	// Device needs to be idle to destroy resources
	vk_device := vulkan_context.device.vk_device
	vk.DeviceWaitIdle(vk_device)

	for semaphore in renderer.image_acquired_semaphores {
		vk.DestroySemaphore(vk_device, semaphore, nil)
	}
	for fence in renderer.fences {
		vk.DestroyFence(vk_device, fence, nil)
	}
	if renderer.command_pool != 0 {
		vk.DestroyCommandPool(vk_device, renderer.command_pool, nil)
	}

	destroy_swapchain(&renderer.swapchain, vulkan_context)
}

@(private = "file")
FRAMES_IN_FLIGHT :: u32(2)

@(private = "file")
CLEAR_COLOR := vk.ClearValue {
	color = {float32 = {0.1, 0.2, 0.4, 1.0}},
}
