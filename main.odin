package ruten

import "core:fmt"
import "core:image/jpeg"
import gl "vendor:OpenGL"
import "window"
import "resources"

main :: proc() {
    main_window := window.init(width = 800, height = 600, title = "Ruten")
    if main_window == nil {
        return
    }
    defer window.cleanup(main_window)

    image_path := "assets/textures/your_name.jpg"
    background_image, error := jpeg.load(filename = image_path)

    if error != nil {
        fmt.eprintln(fmt.tprintf(fmt = "Failed to load %s", args = { image_path }))
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
        fmt.eprintln("Failed to compile/link shaders")
        return
    }
    defer gl.DeleteProgram(gl_program)

    window.loop_until_close(
        window = main_window,
        background_texture = background_texture,
        empty_vao = empty_vao,
        program = gl_program
    )
}