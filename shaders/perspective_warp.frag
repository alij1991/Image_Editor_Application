#version 460 core
#include <flutter/runtime_effect.glsl>

// perspective_warp.frag — projective warp via 3x3 homography.
// The homography is supplied as three vec3 uniforms because Flutter's
// FragmentProgram Dart-side setters don't have a mat3 helper.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec3 u_row0;
uniform vec3 u_row1;
uniform vec3 u_row2;
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec3 src = vec3(uv, 1.0);
    vec3 dst = vec3(dot(u_row0, src), dot(u_row1, src), dot(u_row2, src));
    vec2 warped = dst.xy / dst.z;
    if (warped.x < 0.0 || warped.x > 1.0 || warped.y < 0.0 || warped.y > 1.0) {
        fragColor = vec4(0.0);
    } else {
        fragColor = texture(u_texture, warped);
    }
}
