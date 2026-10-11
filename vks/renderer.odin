package vks

import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Renderer :: struct {
    swapchain:                 Swapchain,
    swapchain_out_of_date:     bool,
    command_pool:              vk.CommandPool,
    command_buffers:           [FRAMES_IN_FLIGHT]vk.CommandBuffer,
    fences:                    [FRAMES_IN_FLIGHT]vk.Fence,
    image_acquired_semaphores: [FRAMES_IN_FLIGHT]vk.Semaphore,
    frame_index:               u32,
    pipeline:                  Pipeline,
    background_texture:        Texture,
    descriptor_pool:           vk.DescriptorPool,
    descriptor_set:            vk.DescriptorSet,
}

// TODO: Document
@(require_results)
create_renderer :: proc(
    gpu_context: Gpu_Context,
    window: glfw.WindowHandle,
) -> (
    renderer: Renderer,
    ok: bool,
) {
    defer if !ok {
        destroy_renderer(&renderer, gpu_context)
    }

    // Swapchain
    swapchain_builder: vkb.Swapchain_Builder
    create_swapchain_builder(&swapchain_builder, gpu_context, window) or_return
    defer vkb.swapchain_builder_uninit(&swapchain_builder)

    create_swapchain(&renderer.swapchain, gpu_context, &swapchain_builder) or_return

    // Command buffers
    vk_device := gpu_context.device.vk_device
    command_pool_create_info := vk.CommandPoolCreateInfo {
        sType            = .COMMAND_POOL_CREATE_INFO,
        pNext            = nil,
        flags            = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = gpu_context.queue_family_index,
    }
    check_success(
        vk.CreateCommandPool(vk_device, &command_pool_create_info, nil, &renderer.command_pool),
        "Failed to create command pool",
    ) or_return

    command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        pNext              = nil,
        level              = .PRIMARY,
        commandBufferCount = FRAMES_IN_FLIGHT,
        commandPool        = renderer.command_pool,
    }
    check_success(
        vk.AllocateCommandBuffers(
            vk_device,
            &command_buffer_allocate_info,
            raw_data(&renderer.command_buffers),
        ),
        "Failed to create command buffers",
    ) or_return

    // Synchronization
    fence_create_info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        pNext = nil,
        flags = {.SIGNALED},
    }
    for &fence, index in renderer.fences {
        check_success(
            vk.CreateFence(vk_device, &fence_create_info, nil, &fence),
            "Failed to create fence #%d",
            index,
        ) or_return
    }

    semaphore_create_info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = nil,
    }
    for &semaphore, index in renderer.image_acquired_semaphores {
        check_success(
            vk.CreateSemaphore(vk_device, &semaphore_create_info, nil, &semaphore),
            "Failed to create image acquired semaphore #%d",
            index,
        ) or_return
    }

    // Pipeline
    renderer.pipeline = create_pipeline(gpu_context) or_return

    // Descriptors
    descriptor_pool_size := vk.DescriptorPoolSize {
        type            = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = MAX_TEXTURES,
    }
    descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
        sType         = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets       = 1,
        poolSizeCount = 1,
        pPoolSizes    = &descriptor_pool_size,
    }
    check_success(
        vk.CreateDescriptorPool(
            vk_device,
            &descriptor_pool_create_info,
            nil,
            &renderer.descriptor_pool,
        ),
        "Failed to create descriptor pool",
    ) or_return

    variable_descriptor_count := u32(MAX_TEXTURES)
    variable_descriptor_count_allocate_info :=
        vk.DescriptorSetVariableDescriptorCountAllocateInfo {
            sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
            descriptorSetCount = 1,
            pDescriptorCounts  = &variable_descriptor_count,
        }
    descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext              = &variable_descriptor_count_allocate_info,
            descriptorPool     = renderer.descriptor_pool,
            descriptorSetCount = 1,
            pSetLayouts        = &renderer.pipeline.descriptor_set_layout,
        }
    check_success(
        vk.AllocateDescriptorSets(
            vk_device,
            &descriptor_set_allocate_info,
            &renderer.descriptor_set,
        ),
        "Failed to allocate descriptor set",
    ) or_return

    return renderer, true
}

// TODO: Document
@(require_results)
draw_frame :: proc(
    renderer: ^Renderer,
    gpu_context: Gpu_Context,
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

    vk_device := gpu_context.device.vk_device
    if renderer.swapchain_out_of_date {
        recreate_swapchain(&renderer.swapchain, gpu_context, window) or_return
        renderer.swapchain_out_of_date = false
    }

    image_index, command_buffer, frame_ready := prepare_frame(renderer, vk_device)
    if !frame_ready {
        return renderer.swapchain_out_of_date
    }

    render_frame(renderer, image_index, command_buffer) or_return
    submit_frame(renderer, gpu_context.queue, image_index, command_buffer) or_return
    present_frame(renderer, gpu_context.queue, &image_index) or_return

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
    // With an infinite timeout, WaitForFences can't return TIMEOUT, so anything but SUCCESS is an error.
    check_success(
        vk.WaitForFences(vk_device, 1, &renderer.fences[frame], true, max(u64)),
        "Failed to wait for fence in frame %d",
        frame,
    ) or_return

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

    check_success(
        vk.ResetFences(vk_device, 1, &renderer.fences[frame]),
        "Failed to reset fence in frame %d",
        frame,
    ) or_return

    command_buffer = renderer.command_buffers[frame]
    check_success(
        vk.ResetCommandBuffer(command_buffer, {}),
        "Failed to reset command buffer in frame %d",
        frame,
    ) or_return

    command_buffer_begin_info := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    check_success(
        vk.BeginCommandBuffer(command_buffer, &command_buffer_begin_info),
        "Failed to begin command buffer in frame %d",
        frame,
    ) or_return

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

    check_success(
        vk.EndCommandBuffer(command_buffer),
        "Failed to end command buffer in frame %d",
        renderer.frame_index,
    ) or_return

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

    check_success(
        vk.QueueSubmit2(queue, 1, &submit_info, renderer.fences[frame]),
        "Failed to submit frame %d",
        frame,
    ) or_return

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

destroy_renderer :: proc(renderer: ^Renderer, gpu_context: Gpu_Context) {
    log.info("Destroying Renderer")
    // Device needs to be idle to destroy resources
    vk_device := gpu_context.device.vk_device
    vk.DeviceWaitIdle(vk_device)

    destroy_texture(&renderer.background_texture, gpu_context)

    if renderer.descriptor_pool != 0 {
        vk.DestroyDescriptorPool(vk_device, renderer.descriptor_pool, nil)
    }

    destroy_pipeline(&renderer.pipeline, gpu_context)

    for semaphore in renderer.image_acquired_semaphores {
        vk.DestroySemaphore(vk_device, semaphore, nil)
    }
    for fence in renderer.fences {
        vk.DestroyFence(vk_device, fence, nil)
    }
    if renderer.command_pool != 0 {
        vk.DestroyCommandPool(vk_device, renderer.command_pool, nil)
    }

    destroy_swapchain(&renderer.swapchain, gpu_context)
}

@(private = "file")
FRAMES_IN_FLIGHT :: u32(2)

@(private = "file")
CLEAR_COLOR := vk.ClearValue {
    color = {float32 = {0.1, 0.2, 0.4, 1.0}},
}
