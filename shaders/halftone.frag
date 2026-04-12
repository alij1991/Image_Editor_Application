#version 460 core
#include <flutter/runtime_effect.glsl>

// halftone.frag — classic circular dot halftone pattern.
// u_dotSize is the cell size in pixels; u_angle rotates the dot grid.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_dotSize;
uniform float u_angle;

out vec4 fragColor;

void main() {
    vec2 pxCoord = FlutterFragCoord().xy;
    float c = cos(u_angle);
    float s = sin(u_angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 rotated = rot * pxCoord;
    vec2 cell = floor(rotated / max(u_dotSize, 1.0));
    vec2 cellCenter = (cell + 0.5) * max(u_dotSize, 1.0);
    vec2 invRot = mat2(c, s, -s, c) * cellCenter;

    vec2 uv = invRot / u_size;
    float lum = dot(texture(u_texture, uv).rgb, vec3(0.2126, 0.7152, 0.0722));

    vec2 offset = rot * pxCoord - (cell + 0.5) * max(u_dotSize, 1.0);
    float dist = length(offset);
    float dotRadius = (1.0 - lum) * max(u_dotSize, 1.0) * 0.5;
    float alpha = 1.0 - smoothstep(dotRadius - 1.0, dotRadius + 1.0, dist);
    fragColor = vec4(vec3(1.0 - alpha), 1.0);
}
