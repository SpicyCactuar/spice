package vks

import "core:bytes"
import "core:image"
import _ "core:image/jpeg"
import "core:log"
import vma "libs:odin-vma"
import vk "vendor:vulkan"

Texture :: struct {
    image:      vk.Image,
    allocation: vma.Allocation,
    extent:     vk.Extent3D,
    view:       vk.ImageView,
    sampler:    vk.Sampler,
}

@(require_results)
create_texture :: proc(
    gpu_context: Gpu_Context,
    image_path: string,
) -> (
    texture: Texture,
    ok: bool,
) {
    log.infof("Creating texture %s", image_path)

    defer if !ok {
        destroy_texture(&texture, gpu_context)
    }

    // Load image
    texture_image, load_error := image.load(
        filename = image_path,
        options = {.alpha_add_if_missing},
    )

    if load_error != nil {
        log.errorf("Failed to load image %s: %v", image_path, load_error)
        return
    }
    defer image.destroy(texture_image)

    max_image_dimension := cast(int)gpu_context.physical_device.vk_properties.limits.maxImageDimension2D
    if texture_image.width > max_image_dimension || texture_image.height > max_image_dimension {
        log.errorf(
            "Rejected texture image %s -- dimensions = (%d x %d), max = %d",
            image_path,
            texture_image.width,
            texture_image.height,
            max_image_dimension,
        )
        return
    }

    if texture_image.channels != TEXTURE_IMAGE_ACCEPTED_CHANNELS {
        log.errorf(
            "Rejected texture image %s -- channels = %d, expected = %d",
            image_path,
            texture_image.channels,
            TEXTURE_IMAGE_ACCEPTED_CHANNELS,
        )
        return
    }

    if texture_image.depth != TEXTURE_IMAGE_ACCEPTED_DEPTH {
        log.errorf(
            "Rejected texture image %s -- depth = %d, expected = %d",
            image_path,
            texture_image.depth,
            TEXTURE_IMAGE_ACCEPTED_DEPTH,
        )
        return
    }

    log.infof(
        "Loaded image %s -- dimensions = (%d x %d), channels = %d, depth = %d",
        image_path,
        texture_image.width,
        texture_image.height,
        texture_image.channels,
        texture_image.depth,
    )

    // Fill staging buffer
    image_pixels := bytes.buffer_to_bytes(&texture_image.pixels)
    image_size_in_bytes := len(image_pixels)

    staging_buffer: vk.Buffer
    staging_allocation: vma.Allocation
    staging_allocation_info: vma.AllocationInfo

    buffer_create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        pNext = nil,
        size  = vk.DeviceSize(image_size_in_bytes),
        usage = {.TRANSFER_SRC},
    }
    allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
        // Filled once via vma.CopyMemoryToAllocation, so no persistent mapping (ie: .MAPPED)
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE},
    }
    check_success(
        vma.CreateBuffer(
            gpu_context.vma_allocator,
            buffer_create_info,
            allocation_create_info,
            &staging_buffer,
            &staging_allocation,
            &staging_allocation_info,
        ),
        "Failed to create staging buffer",
    ) or_return
    defer vma.DestroyBuffer(gpu_context.vma_allocator, staging_buffer, staging_allocation)

    check_success(
        vma.CopyMemoryToAllocation(
            gpu_context.vma_allocator,
            raw_data(image_pixels),
            staging_allocation,
            0, // No offset inside the allocation
            vk.DeviceSize(image_size_in_bytes),
        ),
        "Failed to fill staging buffer",
    ) or_return

    staging_memory_properties: vk.MemoryPropertyFlags
    vma.GetAllocationMemoryProperties(
        gpu_context.vma_allocator,
        staging_allocation,
        &staging_memory_properties,
    )

    log.infof(
        "Created staging buffer: allocated = %d bytes, memory type = %d, properties = %v",
        staging_allocation_info.size,
        staging_allocation_info.memoryType,
        staging_memory_properties,
    )

    // Create vk.Image
    texture.extent = {u32(texture_image.width), u32(texture_image.height), 1}
    image_create_info := vk.ImageCreateInfo {
        sType         = .IMAGE_CREATE_INFO,
        pNext         = nil,
        imageType     = .D2,
        format        = TEXTURE_FORMAT,
        extent        = texture.extent,
        mipLevels     = 1,
        arrayLayers   = 1,
        samples       = {._1},
        tiling        = .OPTIMAL,
        usage         = {.TRANSFER_DST, .SAMPLED},
        initialLayout = .UNDEFINED,
    }

    image_allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
    }
    check_success(
        vma.CreateImage(
            gpu_context.vma_allocator,
            image_create_info,
            image_allocation_create_info,
            &texture.image,
            &texture.allocation,
            nil,
        ),
        "Failed to create texture image",
    ) or_return

    // Start recording upload commands
    upload_command_pool_info := vk.CommandPoolCreateInfo {
        sType            = .COMMAND_POOL_CREATE_INFO,
        pNext            = nil,
        // Hint to indicate GPU drivers that this pool is short-lived
        flags            = {.TRANSIENT},
        queueFamilyIndex = gpu_context.queue_family_index,
    }
    upload_command_pool: vk.CommandPool
    check_success(
        vk.CreateCommandPool(
            gpu_context.device.vk_device,
            &upload_command_pool_info,
            nil,
            &upload_command_pool,
        ),
        "Failed to create image upload command pool",
    ) or_return
    defer vk.DestroyCommandPool(gpu_context.device.vk_device, upload_command_pool, nil)

    upload_command_buffer_info := vk.CommandBufferAllocateInfo {
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        pNext              = nil,
        commandPool        = upload_command_pool,
        level              = .PRIMARY,
        commandBufferCount = 1,
    }
    upload_command_buffer: vk.CommandBuffer
    check_success(
        vk.AllocateCommandBuffers(
            gpu_context.device.vk_device,
            &upload_command_buffer_info,
            &upload_command_buffer,
        ),
        "Failed to allocate image upload command buffer",
    ) or_return

    upload_begin_info := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        pNext = nil,
        flags = {.ONE_TIME_SUBMIT},
    }
    check_success(
        vk.BeginCommandBuffer(upload_command_buffer, &upload_begin_info),
        "Failed to begin upload command buffer",
    ) or_return

    // Transition image to TRANSFER_DST_OPTIMAL
    texture_subresource_range := vk.ImageSubresourceRange {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
    }

    // Barrier 1: UNDEFINED -> TRANSFER_DST_OPTIMAL, so the copy can write into the image
    copy_destination_barrier := vk.ImageMemoryBarrier2 {
        sType            = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask     = {},
        srcAccessMask    = {},
        dstStageMask     = {.COPY},
        dstAccessMask    = {.TRANSFER_WRITE},
        oldLayout        = .UNDEFINED,
        newLayout        = .TRANSFER_DST_OPTIMAL,
        image            = texture.image,
        subresourceRange = texture_subresource_range,
    }
    copy_destination_dependency_info := vk.DependencyInfo {
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &copy_destination_barrier,
    }
    vk.CmdPipelineBarrier2(upload_command_buffer, &copy_destination_dependency_info)

    copy_region := vk.BufferImageCopy2 {
        sType = .BUFFER_IMAGE_COPY_2,
        bufferOffset = 0,
        bufferRowLength = 0,
        bufferImageHeight = 0,
        imageSubresource = {
            aspectMask = {.COLOR},
            mipLevel = 0,
            baseArrayLayer = 0,
            layerCount = 1,
        },
        imageOffset = {},
        imageExtent = texture.extent,
    }
    copy_info := vk.CopyBufferToImageInfo2 {
        sType          = .COPY_BUFFER_TO_IMAGE_INFO_2,
        srcBuffer      = staging_buffer,
        dstImage       = texture.image,
        dstImageLayout = .TRANSFER_DST_OPTIMAL,
        regionCount    = 1,
        pRegions       = &copy_region,
    }
    vk.CmdCopyBufferToImage2(upload_command_buffer, &copy_info)

    // Barrier 2: TRANSFER_DST_OPTIMAL -> SHADER_READ_ONLY_OPTIMAL, so the fragment shader can
    // sample the copied pixels
    shader_read_barrier := vk.ImageMemoryBarrier2 {
        sType            = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask     = {.COPY},
        srcAccessMask    = {.TRANSFER_WRITE},
        dstStageMask     = {.FRAGMENT_SHADER},
        dstAccessMask    = {.SHADER_SAMPLED_READ},
        oldLayout        = .TRANSFER_DST_OPTIMAL,
        newLayout        = .SHADER_READ_ONLY_OPTIMAL,
        image            = texture.image,
        subresourceRange = texture_subresource_range,
    }
    shader_read_dependency_info := vk.DependencyInfo {
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &shader_read_barrier,
    }
    vk.CmdPipelineBarrier2(upload_command_buffer, &shader_read_dependency_info)

    // End recording upload commands
    check_success(
        vk.EndCommandBuffer(upload_command_buffer),
        "Failed to end upload command buffer",
    ) or_return

    // Submit the upload
    fence_create_info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        pNext = nil,
    }
    upload_fence: vk.Fence
    check_success(
        vk.CreateFence(gpu_context.device.vk_device, &fence_create_info, nil, &upload_fence),
        "Failed to create texture image upload fence",
    ) or_return
    defer vk.DestroyFence(gpu_context.device.vk_device, upload_fence, nil)

    upload_command_buffer_submit_info := vk.CommandBufferSubmitInfo {
        sType         = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer = upload_command_buffer,
    }
    upload_submit_info := vk.SubmitInfo2 {
        sType                  = .SUBMIT_INFO_2,
        commandBufferInfoCount = 1,
        pCommandBufferInfos    = &upload_command_buffer_submit_info,
    }
    check_success(
        vk.QueueSubmit2(gpu_context.queue, 1, &upload_submit_info, upload_fence),
        "Failed to submit texture upload",
    ) or_return

    // Wait for upload to finish
    check_success(
        vk.WaitForFences(gpu_context.device.vk_device, 1, &upload_fence, true, max(u64)),
        "Failed to wait for texture upload",
    ) or_return

    // Create texture image view
    view_create_info := vk.ImageViewCreateInfo {
        sType            = .IMAGE_VIEW_CREATE_INFO,
        image            = texture.image,
        viewType         = .D2,
        format           = TEXTURE_FORMAT,
        subresourceRange = texture_subresource_range,
    }
    check_success(
        vk.CreateImageView(gpu_context.device.vk_device, &view_create_info, nil, &texture.view),
        "Failed to create texture image view",
    ) or_return

    max_anisotropy := min(
        TEXTURE_MAX_ANISOTROPY,
        gpu_context.physical_device.vk_properties.limits.maxSamplerAnisotropy,
    )
    sampler_create_info := vk.SamplerCreateInfo {
        sType            = .SAMPLER_CREATE_INFO,
        magFilter        = .LINEAR,
        minFilter        = .LINEAR,
        mipmapMode       = .LINEAR,
        // Clamp so linear filtering at the edges doesn't blend in pixels from the opposite edge
        addressModeU     = .CLAMP_TO_EDGE,
        addressModeV     = .CLAMP_TO_EDGE,
        addressModeW     = .CLAMP_TO_EDGE,
        anisotropyEnable = true,
        maxAnisotropy    = max_anisotropy,
        minLod           = 0,
        maxLod           = 1, // The image has a single mip level
    }
    check_success(
        vk.CreateSampler(
            gpu_context.device.vk_device,
            &sampler_create_info,
            nil,
            &texture.sampler,
        ),
        "Failed to create texture sampler",
    ) or_return

    log.infof("Created texture %s", image_path)

    return texture, true
}

destroy_texture :: proc(texture: ^Texture, gpu_context: Gpu_Context) {
    vk_device := gpu_context.device.vk_device
    if texture.sampler != 0 {
        vk.DestroySampler(vk_device, texture.sampler, nil)
    }
    if texture.view != 0 {
        vk.DestroyImageView(vk_device, texture.view, nil)
    }
    if texture.image != 0 {
        vma.DestroyImage(gpu_context.vma_allocator, texture.image, texture.allocation)
    }
}

@(private = "file")
TEXTURE_IMAGE_ACCEPTED_CHANNELS :: 4
@(private = "file")
TEXTURE_IMAGE_ACCEPTED_DEPTH :: 8
@(private = "file")
TEXTURE_FORMAT :: vk.Format.R8G8B8A8_SRGB
// Max anisotropic filtering samples, as in How to Vulkan. Clamped to the device limit when used.
// See: https://github.com/SaschaWillems/HowToVulkan/blob/main/source/main.cpp#L377
@(private = "file")
TEXTURE_MAX_ANISOTROPY :: 8.0
