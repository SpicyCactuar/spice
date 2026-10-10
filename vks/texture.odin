package vks

import "core:image"
import _ "core:image/jpeg"
import "core:log"

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

    return texture, true
}

destroy_texture :: proc(texture: ^Texture) {
}

@(private = "file")
TEXTURE_IMAGE_ACCEPTED_CHANNELS :: 4
@(private = "file")
TEXTURE_IMAGE_ACCEPTED_DEPTH :: 8
