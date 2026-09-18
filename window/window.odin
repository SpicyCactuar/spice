package window

import "core:fmt"
import "core:log"
import gl "vendor:OpenGL"
import "vendor:glfw"

Window :: struct {
	handle:        glfw.WindowHandle,
	title:         string,
	width, height: i32,
}

create_window :: proc(width, height: i32, title: string) -> (window: Window, ok: bool) {
	if !glfw.Init() {
		log.error("Failed to initialize GLFW")
		return
	}

	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 6)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window_handle := glfw.CreateWindow(width, height, fmt.ctprintf(title), nil, nil)
	if window_handle == nil {
		log.error("Could not create GLFW window")
		glfw.Terminate()
		return
	}

	glfw.MakeContextCurrent(window_handle)
	gl.load_up_to(4, 6, glfw.gl_set_proc_address)

	return Window{handle = window_handle, title = title, width = width, height = height}, true
}

loop_until_close :: proc(window: Window, background_texture: u32, empty_vao: u32, program: u32) {
	glfw.SetKeyCallback(window.handle, close_on_escape_pressed)

	gl.UseProgram(program)
	gl.Uniform1i(gl.GetUniformLocation(program, "u_texture"), 0)

	for !glfw.WindowShouldClose(window.handle) {
		width, height := glfw.GetFramebufferSize(window.handle)
		gl.Viewport(0, 0, width, height)

		gl.Clear(gl.COLOR_BUFFER_BIT)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, background_texture)
		gl.BindVertexArray(empty_vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)

		glfw.SwapBuffers(window.handle)
		glfw.PollEvents()
	}
}

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

cleanup :: proc(window: Window) {
	log.info("Terminating Window")
	glfw.DestroyWindow(window.handle)
	glfw.Terminate()
}
