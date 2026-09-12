#version 460 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;

void main() {
    frag_color = texture(u_texture, vec2(v_uv.x, 1.0 - v_uv.y));
}