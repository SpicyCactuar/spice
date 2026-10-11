package vks

import "core:bytes"
import "core:image"
import _ "core:image/jpeg"
import "core:log"
import "core:mem"
import vma "libs:odin-vma"
import vk "vendor:vulkan"

Texture :: struct {
    image:      vk.Image,
    allocation: vma.Allocation,
    extent:     vk.Extent3D,
}

@(require_results)
create_texture :: proc(
    gpu_context: Gpu_Context,
    image_path: string,
) -> (
    texture: Texture,
    ok: bool,
) {
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

    staging_buffer: vk.Buffer
    staging_allocation: vma.Allocation
    staging_allocation_info: vma.AllocationInfo

    buffer_create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        pNext = nil,
        size  = vk.DeviceSize(len(image_pixels)),
        usage = {.TRANSFER_SRC},
    }
    allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
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

    staging_memory_properties: vk.MemoryPropertyFlags
    vma.GetAllocationMemoryProperties(
        gpu_context.vma_allocator,
        staging_allocation,
        &staging_memory_properties,
    )

    mem.copy(staging_allocation_info.pMappedData, raw_data(image_pixels), len(image_pixels))
    check_success(
        vma.FlushAllocation(
            gpu_context.vma_allocator,
            staging_allocation,
            0,
            vk.DeviceSize(len(image_pixels)),
        ),
        "Failed to flush staging buffer",
    ) or_return

    log.infof(
        "Created staging buffer: size = %d bytes, memory type = %d, properties = %v, mapped = %p",
        staging_allocation_info.size,
        staging_allocation_info.memoryType,
        staging_memory_properties,
        staging_allocation_info.pMappedData,
    )

    // Create vk.Image
    texture.extent = {u32(texture_image.width), u32(texture_image.height), 1}
    image_create_info := vk.ImageCreateInfo {
        sType         = .IMAGE_CREATE_INFO,
        pNext         = nil,
        imageType     = .D2,
        format        = .R8G8B8A8_SRGB,
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

    return texture, true
}

destroy_texture :: proc(texture: ^Texture, gpu_context: Gpu_Context) {
    if texture.image != 0 {
        vma.DestroyImage(gpu_context.vma_allocator, texture.image, texture.allocation)
    }
}

@(private = "file")
TEXTURE_IMAGE_ACCEPTED_CHANNELS :: 4
@(private = "file")
TEXTURE_IMAGE_ACCEPTED_DEPTH :: 8
