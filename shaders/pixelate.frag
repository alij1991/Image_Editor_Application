#version 460 core
#include <flutter/runtime_effect.glsl>

// pixelate.frag — mosaic effect.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_pixelSize; // cell size in pixels
out vec4 fragColor;
void main() {
    vec2 pxCoord = FlutterFragCoord().xy;
    float sz = max(u_pixelSize, 1.0);
    vec2 cell = floor(pxCoord / sz) * sz + sz * 0.5;
    vec2 uv = cell / u_size;
    fragColor = texture(u_texture, uv);
}
