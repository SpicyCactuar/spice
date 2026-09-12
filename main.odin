package ruten

import "core:fmt"
import "core:image/jpeg"
import "vendor:glfw"
import gl "vendor:OpenGL"

main :: proc() {
    window := init_window(800, 600, "Ruten")
    if window == nil {
        return
    }
    defer cleanup(window)

    background_image, error := jpeg.load("assets/textures/your_name.jpg")

    if error != nil {
        fmt.eprintln("Failed to load assets/textures/your_name.jpg")
        return
    }
    defer jpeg.destroy(background_image)

    background_texture := create_texture(background_image)
    defer gl.DeleteTextures(1, &background_texture)

    empty_vao: u32
    gl.GenVertexArrays(1, &empty_vao)
    defer gl.DeleteVertexArrays(1, &empty_vao)

    gl_program, gl_program_compiled := gl.load_shaders("shaders/main.vert", "shaders/main.frag")
    if !gl_program_compiled {
        fmt.eprintln("Failed to compile/link shaders")
        return
    }
    defer gl.DeleteProgram(gl_program)

    loop_until_close(window, background_texture, empty_vao, gl_program)
}

init_window :: proc(width, height: i32, title: cstring) -> glfw.WindowHandle {
    if !glfw.Init() {
        fmt.eprintln("glfw.Init() error")
        return nil
    }

    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 6)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

    window := glfw.CreateWindow(width, height, title, nil, nil)
    if window == nil {
        fmt.eprintln("Could not create window")
        glfw.Terminate()
        return nil
    }

    glfw.MakeContextCurrent(window)
    gl.load_up_to(4, 5, glfw.gl_set_proc_address)

    return window
}

create_texture :: proc(img: ^jpeg.Image) -> u32 {
    format : u32 = gl.RGBA if img.channels == 4 else gl.RGB

    texture: u32
    gl.GenTextures(1, &texture)
    gl.BindTexture(gl.TEXTURE_2D, texture)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1) // JPEG rows aren't 4-byte aligned

    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

    gl.TexImage2D(
        gl.TEXTURE_2D,
        0,
        i32(format),
        i32(img.width),
        i32(img.height),
        0,
        format,
        gl.UNSIGNED_BYTE,
        raw_data(img.pixels.buf),
    )

    return texture
}

loop_until_close :: proc(window: glfw.WindowHandle, texture: u32, empty_vao: u32, program: u32) {
    glfw.SetKeyCallback(window, is_escape_pressed)

    gl.UseProgram(program)
    gl.Uniform1i(gl.GetUniformLocation(program, "u_texture"), 0)

    for !glfw.WindowShouldClose(window) {
        width, height := glfw.GetFramebufferSize(window)
        gl.Viewport(0, 0, width, height)

        gl.Clear(gl.COLOR_BUFFER_BIT)
        gl.ActiveTexture(gl.TEXTURE0)
        gl.BindTexture(gl.TEXTURE_2D, texture)
        gl.BindVertexArray(empty_vao)
        gl.DrawArrays(gl.TRIANGLES, 0, 3)

        glfw.SwapBuffers(window)
        glfw.PollEvents()
    }
}

is_escape_pressed :: proc "c" (window: glfw.WindowHandle, key: i32, scancode: i32, action: i32, mods: i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(window, true)
    }
}

cleanup :: proc(window: glfw.WindowHandle) {
    fmt.println("Terminating Window")
    glfw.DestroyWindow(window)
    glfw.Terminate()
}