#version 460 core
#include <flutter/runtime_effect.glsl>

// tilt_shift.frag — linear-masked Gaussian blur.
// The "focus strip" is a line (not necessarily horizontal) at u_focusPos,
// rotated by u_angle radians and with width u_focusWidth. Pixels inside
// the strip are sharp; pixels outside fade to blurred via smoothstep.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform vec2 u_focusPos;   // normalized 0..1
uniform float u_focusWidth;// normalized half-width of sharp band
uniform float u_blurAmount;// 0..1
uniform float u_angle;     // radians

out vec4 fragColor;

vec3 sampleBlurred(vec2 uv) {
    // 9-tap separable-ish box blur at a strength-scaled radius.
    float r = u_blurAmount * 6.0;
    vec2 texel = r / u_size;
    vec3 acc = vec3(0.0);
    float total = 0.0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            vec2 off = vec2(float(x), float(y)) * texel * 0.5;
            acc += texture(u_texture, uv + off).rgb;
            total += 1.0;
        }
    }
    return acc / total;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    vec3 blurred = sampleBlurred(uv);

    vec2 delta = uv - u_focusPos;
    // Project onto the normal of the rotation angle.
    vec2 normal = vec2(-sin(u_angle), cos(u_angle));
    float dist = abs(dot(delta, normal));
    float t = smoothstep(u_focusWidth, u_focusWidth * 2.0, dist);

    vec3 outColor = mix(src.rgb, blurred, t);
    fragColor = vec4(outColor, src.a);
}
