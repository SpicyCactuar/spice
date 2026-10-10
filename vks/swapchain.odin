package vks

import "core:log"
import vkb "libs:odin-vk-bootstrap"
import "vendor:glfw"
import vk "vendor:vulkan"

Swapchain :: struct {
    vkb_swapchain:              vkb.Swapchain,
    images:                     []vk.Image,
    image_views:                []vk.ImageView,
    render_complete_semaphores: []vk.Semaphore,
}

// TODO: Document
@(private)
@(require_results)
create_swapchain :: proc(
    swapchain: ^Swapchain,
    gpu_context: Gpu_Context,
    swapchain_builder: ^vkb.Swapchain_Builder,
) -> (
    ok: bool,
) {
    check_success(
        vkb.swapchain_builder_build(swapchain_builder, &swapchain.vkb_swapchain),
        "Failed to build swapchain",
    ) or_return

    log.infof(
        "Built swapchain: %d image(s), %d x %d, %v, %v",
        swapchain.vkb_swapchain.image_count,
        swapchain.vkb_swapchain.vk_extent.width,
        swapchain.vkb_swapchain.vk_extent.height,
        swapchain.vkb_swapchain.vk_image_format,
        swapchain.vkb_swapchain.vk_present_mode,
    )

    // Swapchain images and image views
    swapchain.images = check_success(
        vkb.swapchain_get_images(swapchain.vkb_swapchain),
        "Failed to get swapchain images",
    ) or_return

    swapchain.image_views = check_success(
        vkb.swapchain_get_image_views(swapchain.vkb_swapchain),
        "Failed to create swapchain image views",
    ) or_return

    semaphore_create_info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = nil,
    }
    swapchain.render_complete_semaphores = make([]vk.Semaphore, len(swapchain.images))
    for &semaphore, index in swapchain.render_complete_semaphores {
        check_success(
            vk.CreateSemaphore(
                gpu_context.device.vk_device,
                &semaphore_create_info,
                nil,
                &semaphore,
            ),
            "Failed to create render complete semaphore #%d",
            index,
        ) or_return
    }

    return true
}

@(private)
swapchain_handle :: proc(swapchain: Swapchain) -> vk.SwapchainKHR {
    return swapchain.vkb_swapchain.vk_swapchain
}

@(private)
swapchain_extent :: proc(swapchain: Swapchain) -> vk.Extent2D {
    return swapchain.vkb_swapchain.vk_extent
}

// TODO: Document
@(private)
@(require_results)
recreate_swapchain :: proc(
    swapchain: ^Swapchain,
    gpu_context: Gpu_Context,
    window: glfw.WindowHandle,
) -> (
    ok: bool,
) {
    check_success(
        vk.DeviceWaitIdle(gpu_context.device.vk_device),
        "Failed to wait for device idle",
    ) or_return

    // The old swapchain is handed to the new one as `oldSwapchain`, so it must outlive the build.
    // It is retired either way, so it is destroyed whether the build succeeds or not.
    old_swapchain := swapchain^
    swapchain^ = {}
    defer destroy_swapchain(&old_swapchain, gpu_context)

    swapchain_builder: vkb.Swapchain_Builder
    create_swapchain_builder(
        &swapchain_builder,
        gpu_context,
        window,
        swapchain_handle(old_swapchain),
    ) or_return
    defer vkb.swapchain_builder_uninit(&swapchain_builder)

    return create_swapchain(swapchain, gpu_context, &swapchain_builder)
}

// TODO: Document
@(private)
@(require_results)
create_swapchain_builder :: proc(
    swapchain_builder: ^vkb.Swapchain_Builder,
    gpu_context: Gpu_Context,
    window: glfw.WindowHandle,
    old_swapchain: vk.SwapchainKHR = 0,
) -> (
    ok: bool,
) {
    // Surface capabilities
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check_success(
        vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
            gpu_context.physical_device.vk_physical_device,
            gpu_context.surface,
            &surface_capabilities,
        ),
        "Failed to query surface capabilities",
    ) or_return

    // On Wayland the surface has no size of its own (0xFFFFFFFF), and the
    // swapchain decides it, so use the window's framebuffer size instead.
    desired_extent := surface_capabilities.currentExtent
    if surface_capabilities.currentExtent.width == max(u32) {
        width, height := glfw.GetFramebufferSize(window)
        desired_extent = {u32(width), u32(height)}
    }

    // Only the surface query above can fail, so an initialized builder means success.
    vkb.swapchain_builder_init(
        swapchain_builder,
        gpu_context.physical_device,
        gpu_context.device,
        gpu_context.surface,
        gpu_context.queue_family_index,
        gpu_context.queue_family_index,
    )

    vkb.swapchain_builder_set_desired_min_image_count(
        swapchain_builder,
        surface_capabilities.minImageCount,
    )
    vkb.swapchain_builder_set_desired_format(
        swapchain_builder,
        {format = .B8G8R8A8_SRGB, colorSpace = .SRGB_NONLINEAR},
    )
    vkb.swapchain_builder_set_desired_extent(
        swapchain_builder,
        desired_extent.width,
        desired_extent.height,
    )
    vkb.swapchain_builder_set_image_array_layer_count(swapchain_builder, 1)
    vkb.swapchain_builder_set_image_usage_flags(swapchain_builder, {.COLOR_ATTACHMENT})
    vkb.swapchain_builder_set_pre_transform_flags(swapchain_builder, {.IDENTITY})
    vkb.swapchain_builder_set_composite_alpha_flags(swapchain_builder, {.OPAQUE})
    vkb.swapchain_builder_set_desired_present_mode(swapchain_builder, .FIFO)
    vkb.swapchain_builder_set_old_swapchain(swapchain_builder, old_swapchain)

    return true
}

@(private)
destroy_swapchain :: proc(swapchain: ^Swapchain, gpu_context: Gpu_Context) {
    vk_device := gpu_context.device.vk_device
    for semaphore in swapchain.render_complete_semaphores {
        vk.DestroySemaphore(vk_device, semaphore, nil)
    }
    delete(swapchain.render_complete_semaphores)

    if swapchain.image_views != nil {
        vkb.swapchain_destroy_image_views(swapchain.vkb_swapchain, swapchain.image_views)
        delete(swapchain.image_views)
    }

    // Swapchain images are owned by the swapchain, so only the slice is freed
    delete(swapchain.images)
    if swapchain_handle(swapchain^) != 0 {
        vkb.destroy_swapchain(&swapchain.vkb_swapchain)
    }
}
