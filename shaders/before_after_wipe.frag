#version 460 core
#include <flutter/runtime_effect.glsl>

// before_after_wipe.frag — split-view comparison.
// Draws the current pipeline on one side of u_splitPos and the original on
// the other. u_angle lets the split line rotate for diagonal wipes.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;  // edited
uniform sampler2D u_original; // original
uniform float u_splitPos;     // 0..1
uniform float u_angle;        // radians
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 centered = uv - 0.5;
    float c = cos(u_angle);
    float s = sin(u_angle);
    float rotX = centered.x * c + centered.y * s + 0.5;
    fragColor = rotX < u_splitPos
        ? texture(u_texture, uv)
        : texture(u_original, uv);
}
