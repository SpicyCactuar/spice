package window

import "../vks"
import "core:fmt"
import "core:log"
import "core:slice"
import "vendor:glfw"

Window :: struct {
    handle:          glfw.WindowHandle,
    title:           string,
    width, height:   i32,
    vulkan_context:  vks.Gpu_Context,
    vulkan_renderer: vks.Renderer,
}

create :: proc(title: string, width, height: i32) -> (window: Window, ok: bool) {
    defer if !ok {
        destroy(&window)
    }

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

    window.title = title
    window.width = width
    window.height = height
    window.handle = glfw.CreateWindow(width, height, fmt.ctprintf("%s", title), nil, nil)
    if window.handle == nil {
        log.error("Could not create GLFW window")
        return
    }

    instance_extensions_c := glfw.GetRequiredInstanceExtensions()
    if len(instance_extensions_c) == 0 {
        log.error("no Vulkan extensions found, need at least 'VK_KHR_surface'")
        return
    }

    log.infof("Found %d Vulkan extension(s)", len(instance_extensions_c))
    instance_extensions, _ := slice.mapper(
        instance_extensions_c,
        proc(extension_c: cstring) -> string {
            return string(extension_c)
        },
    )
    defer delete(instance_extensions)
    for extension in instance_extensions {
        log.info(extension)
    }

    vulkan_context, context_initialized := vks.create_gpu_context(
        instance_extensions = instance_extensions,
        window = window.handle,
    )
    if !context_initialized {
        log.error("Failed to initialize Vulkan Context")
        return
    }
    window.vulkan_context = vulkan_context

    renderer, renderer_initialized := vks.create_renderer(
        gpu_context = vulkan_context,
        window = window.handle,
    )
    if !renderer_initialized {
        log.errorf("Failed to initialize Renderer")
        return
    }
    window.vulkan_renderer = renderer

    return window, true
}

@(require_results)
set_background_image :: proc(window: ^Window, image_path: string) -> (ok: bool) {
    window.vulkan_renderer.background_texture = vks.create_texture(
        window.vulkan_context,
        image_path,
    ) or_return

    return true
}

loop_until_close :: proc(window: ^Window) {
    log.info("Looping until window is closed")
    glfw.SetKeyCallback(window.handle, close_on_escape_pressed)

    for !glfw.WindowShouldClose(window.handle) {
        // While minimized there is nothing to draw, so sleep until an event (e.g. restoring the
        // window) arrives instead of spinning. Otherwise, keep rendering every iteration.
        width, height := glfw.GetFramebufferSize(window.handle)
        if width == 0 || height == 0 {
            glfw.WaitEvents()
            continue
        }

        glfw.PollEvents()
        frame_drawn := vks.draw_frame(
            &window.vulkan_renderer,
            window.vulkan_context,
            window.handle,
        )
        if !frame_drawn {
            log.errorf("Failed to draw frame: %d", window.vulkan_renderer.frame_index)
            return
        }
    }
}

@(private = "file")
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

destroy :: proc(window: ^Window) {
    log.info("Terminating Window")
    release_renderer(window)
    release_vulkan_context(window)
    release_glfw(window)
}

// The renderer's swapchain depends on the Vulkan context, so it must be released first.
@(private = "file")
release_renderer :: proc(window: ^Window) {
    vks.destroy_renderer(&window.vulkan_renderer, window.vulkan_context)
    window.vulkan_renderer = {}
}

@(private = "file")
release_vulkan_context :: proc(window: ^Window) {
    vks.destroy_gpu_context(&window.vulkan_context)
    window.vulkan_context = {}
}

@(private = "file")
release_glfw :: proc(window: ^Window) {
    if window.handle != nil {
        glfw.DestroyWindow(window.handle)
    }
    window.handle = nil
    glfw.Terminate()
}
