package vks

import "core:bytes"
import "core:image"
import _ "core:image/jpeg"
import "core:log"
import vma "libs:odin-vma"
import vk "vendor:vulkan"

Texture :: struct {}

@(require_results)
create_texture :: proc(
    gpu_context: Gpu_Context,
    image_path: string,
) -> (
    texture: Texture,
    ok: bool,
) {
    defer if !ok {
        destroy_texture(&texture)
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

    // Create staging buffer
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
    staging_buffer_result := vma.CreateBuffer(
        gpu_context.vma_allocator,
        buffer_create_info,
        allocation_create_info,
        &staging_buffer,
        &staging_allocation,
        &staging_allocation_info,
    )

    if staging_buffer_result != .SUCCESS {
        log.errorf("Failed to create staging buffer: %v", staging_buffer_result)
        return
    }
    defer vma.DestroyBuffer(gpu_context.vma_allocator, staging_buffer, staging_allocation)

    staging_memory_properties: vk.MemoryPropertyFlags
    vma.GetAllocationMemoryProperties(
        gpu_context.vma_allocator,
        staging_allocation,
        &staging_memory_properties,
    )

    log.infof(
        "Created staging buffer: size = %d bytes, memory type = %d, properties = %v, mapped = %p",
        staging_allocation_info.size,
        staging_allocation_info.memoryType,
        staging_memory_properties,
        staging_allocation_info.pMappedData,
    )

    return texture, true
}

destroy_texture :: proc(texture: ^Texture) {
}

@(private = "file")
TEXTURE_IMAGE_ACCEPTED_CHANNELS :: 4
@(private = "file")
TEXTURE_IMAGE_ACCEPTED_DEPTH :: 8
