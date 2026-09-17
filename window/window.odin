package window

import "core:fmt"
import "vendor:glfw"
import gl "vendor:OpenGL"

init :: proc(width, height: i32, title: cstring) -> glfw.WindowHandle {
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

loop_until_close :: proc(window: glfw.WindowHandle, background_texture: u32, empty_vao: u32, program: u32) {
    glfw.SetKeyCallback(window, close_on_escape_pressed)

    gl.UseProgram(program)
    gl.Uniform1i(gl.GetUniformLocation(program, "u_texture"), 0)

    for !glfw.WindowShouldClose(window) {
        width, height := glfw.GetFramebufferSize(window)
        gl.Viewport(0, 0, width, height)

        gl.Clear(gl.COLOR_BUFFER_BIT)
        gl.ActiveTexture(gl.TEXTURE0)
        gl.BindTexture(gl.TEXTURE_2D, background_texture)
        gl.BindVertexArray(empty_vao)
        gl.DrawArrays(gl.TRIANGLES, 0, 3)

        glfw.SwapBuffers(window)
        glfw.PollEvents()
    }
}

close_on_escape_pressed :: proc "c" (window: glfw.WindowHandle, key: i32, scancode: i32, action: i32, mods: i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(window, true)
    }
}

cleanup :: proc(window: glfw.WindowHandle) {
    fmt.println("Terminating Window")
    glfw.DestroyWindow(window)
    glfw.Terminate()
}