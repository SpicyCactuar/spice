package resources

import "core:image/jpeg"
import gl "vendor:OpenGL"

create_texture :: proc(image: ^jpeg.Image) -> u32 {
	format: u32 = gl.RGBA if image.channels == 4 else gl.RGB

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
		i32(image.width),
		i32(image.height),
		0,
		format,
		gl.UNSIGNED_BYTE,
		raw_data(image.pixels.buf),
	)

	return texture
}
