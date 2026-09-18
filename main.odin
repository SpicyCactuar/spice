package ruten

import "core:image/jpeg"
import "core:log"
import "resources"
import gl "vendor:OpenGL"
import "window"

main :: proc() {
	context.logger = log.create_console_logger()

	main_window, created_window := window.create_window(width = 800, height = 600, title = "Ruten")
	if !created_window {
		return
	}
	defer window.cleanup(main_window)

	image_path := "assets/textures/your_name.jpg"
	background_image, error := jpeg.load(filename = image_path)

	if error != nil {
		log.errorf("Failed to load %s", image_path)
		return
	}
	defer jpeg.destroy(background_image)

	background_texture := resources.create_texture(image = background_image)
	defer gl.DeleteTextures(1, &background_texture)

	empty_vao: u32
	gl.GenVertexArrays(1, &empty_vao)
	defer gl.DeleteVertexArrays(1, &empty_vao)

	gl_program, gl_program_compiled := gl.load_shaders("shaders/main.vert", "shaders/main.frag")
	if !gl_program_compiled {
		log.error("Failed to compile/link shaders")
		return
	}
	defer gl.DeleteProgram(gl_program)

	window.loop_until_close(
		window = main_window,
		background_texture = background_texture,
		empty_vao = empty_vao,
		program = gl_program,
	)
}
