#version 460 core
#include <flutter/runtime_effect.glsl>

// lens_blur.frag — XVI.40 depth-aware lens blur (the marquee
// differentiator vs. Snapseed).
//
// Two-sampler pass: u_texture is the source RGB, u_depth is the
// single-channel inverse-depth map produced by Depth-Anything-V2-Small
// (higher = closer). The shader computes per-pixel circle of confusion
// (CoC) from the difference between the pixel's depth and the user's
// focus depth (sampled at u_focusX, u_focusY), then averages a
// 24-tap disc-pattern of texture samples within that CoC.
//
// Bokeh shape uniform u_bokehShape (int-cast in Dart):
//   0 = round (uniform disc)
//   1 = 5-blade aperture (pentagonal mask via cosine periodicity)
//   2 = cat's-eye (anisotropic vignette toward image edges; mimics a
//       mechanical front-element vignette on fast lenses)
//
// All taps run in linear RGB space — sRGB → linear → blur → sRGB on
// the way out — so highlight bokeh balls retain their saturated cores
// instead of muddying to grey when blurred.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_depth;

uniform float u_aperture;    // 0..1 — bokeh radius scale
uniform float u_focusX;      // 0..1 — normalised focus point X
uniform float u_focusY;      // 0..1 — normalised focus point Y
uniform float u_bokehShape;  // 0=circle, 1=5-blade, 2=cat's-eye

out vec4 fragColor;

const int kTapCount = 24;
const float TAU = 6.28318530718;

// Maximum bokeh radius in fraction-of-image-width units. At
// u_aperture=1 a fully out-of-focus pixel reaches across ~6% of the
// frame — enough for a clear bokeh disc on portraits without the
// blur kernel spanning into unrelated regions. Aperture scales this
// linearly.
const float kMaxRadius = 0.06;

// sRGB ↔ linear (per-channel piecewise IEC 61966-2-1).
vec3 srgbToLinear(vec3 c) {
    bvec3 cutoff = lessThan(c, vec3(0.04045));
    vec3 lo = c / 12.92;
    vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(hi, lo, vec3(cutoff));
}

vec3 linearToSrgb(vec3 c) {
    c = max(c, vec3(0.0));
    bvec3 cutoff = lessThan(c, vec3(0.0031308));
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

// Read inverse depth at uv. Depth model output is single-channel
// stored in the red channel of a grayscale ui.Image. Other channels
// hold the same value (we encode grayscale as a luminance copy on the
// Dart side) so the .r read works regardless of upload format.
float depthAt(vec2 uv) {
    return texture(u_depth, clamp(uv, 0.0, 1.0)).r;
}

// 5-blade pentagonal aperture mask. Returns 1.0 inside the
// pentagon, 0.0 outside. Centre is (0,0); polar radius/angle of the
// disc tap point is the input.
float pentagonMask(float r, float theta) {
    // 5-fold symmetry: angle modulo TAU/5.
    float seg = TAU / 5.0;
    float a = mod(theta + seg * 0.5, seg) - seg * 0.5;
    // Pentagon edge distance: cos(a) is the perpendicular projection
    // of the unit-disc radius onto the segment normal. A circle of
    // radius `r` is inside the pentagon when r * cos(a) ≤ apothem.
    float apothem = cos(seg * 0.5); // ≈ 0.809 for 5-blade
    return r * cos(a) <= apothem ? 1.0 : 0.0;
}

// Cat's-eye anisotropic mask. Stretches the bokeh tangentially when
// the pixel is far from the image centre, mimicking the mechanical
// vignette of a fast prime lens at full aperture.
float catsEyeWeight(vec2 pixelUv, vec2 tap) {
    vec2 fromCentre = pixelUv - vec2(0.5);
    float distFromCentre = length(fromCentre);
    if (distFromCentre < 0.05) return 1.0; // round near the centre
    vec2 radial = fromCentre / max(distFromCentre, 1e-4);
    // Tangential = perpendicular to radial. A tap that points toward
    // the radial direction shrinks (cut by the rear-element edge);
    // a tap perpendicular to radial passes through unchanged.
    float radialAlign = abs(dot(normalize(tap + vec2(1e-4)), radial));
    // Stretch factor falls smoothly with distance from the centre —
    // 1.0 at centre, 0.5 at the corners.
    float stretch = mix(1.0, 0.5, smoothstep(0.05, 0.7, distFromCentre));
    return mix(1.0, stretch, radialAlign);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Identity short-circuit. Aperture below threshold → no blur.
    if (u_aperture < 1e-3) {
        fragColor = src;
        return;
    }

    // Focus depth: read the depth map at the user's tap point.
    vec2 focusUv = vec2(clamp(u_focusX, 0.0, 1.0),
                       clamp(u_focusY, 0.0, 1.0));
    float focusDepth = depthAt(focusUv);
    float pixelDepth = depthAt(uv);

    // Circle of confusion. |Δdepth| × aperture → blur radius in uv
    // space. Clamp to kMaxRadius to keep the kernel bounded.
    float coc = abs(pixelDepth - focusDepth) * u_aperture * kMaxRadius;
    if (coc < 1e-4) {
        fragColor = src; // pixel is in focus
        return;
    }

    // Aspect-correct radius: convert UV-space radius to per-axis
    // sample steps so a circular disc on screen samples a circular
    // region in pixel space (not stretched on non-square images).
    float aspect = u_size.x / max(u_size.y, 1.0);
    vec2 radiusUv = vec2(coc / aspect, coc);

    // Disc-pattern accumulator. We sample a fixed 24-tap spiral —
    // ~6 angular steps × 4 radial rings — gives even angular
    // coverage with 24 texture reads.
    vec3 accum = vec3(0.0);
    float weightSum = 0.0;
    int shape = int(u_bokehShape + 0.5);

    for (int i = 0; i < kTapCount; i++) {
        // Spiral mapping: each tap moves both radially (r) and
        // angularly (theta). Golden-ratio angular step distributes
        // the 24 taps with no visible directional banding.
        float t = (float(i) + 0.5) / float(kTapCount);
        float r = sqrt(t); // uniform area distribution
        float theta = float(i) * 2.39996; // golden angle (rad)

        vec2 disc = vec2(cos(theta), sin(theta)) * r;
        vec2 sampleUv = uv + disc * radiusUv;

        // Per-tap weight from bokeh-shape mask.
        float w;
        if (shape == 1) {
            w = pentagonMask(r, theta);
        } else if (shape == 2) {
            w = catsEyeWeight(uv, disc);
        } else {
            w = 1.0; // circle
        }

        // Foreground bleed protection: if the tap pixel is more
        // out-of-focus than the centre pixel, weight it down — this
        // stops sharp foreground subjects bleeding into the blurred
        // background ring around them. Standard CoC-aware bokeh
        // weighting.
        float tapDepth = depthAt(sampleUv);
        float tapCoc = abs(tapDepth - focusDepth) * u_aperture * kMaxRadius;
        // Allow the tap if its CoC is at least as wide as the
        // centre's CoC (background bokeh) OR if it sits inside the
        // centre's disc (in-focus pixel sampling its own
        // neighbourhood).
        if (tapCoc + 1e-4 < coc * 0.5) {
            w = 0.0;
        }

        if (w > 0.0) {
            vec3 tap = srgbToLinear(texture(u_texture, sampleUv).rgb);
            accum += tap * w;
            weightSum += w;
        }
    }

    // Fall back to source when every tap was masked out (rare —
    // occurs only at the image edge with cat's-eye and tight
    // foreground).
    if (weightSum < 1e-4) {
        fragColor = src;
        return;
    }

    vec3 blurredLin = accum / weightSum;
    vec3 outRgb = linearToSrgb(clamp(blurredLin, 0.0, 1.0));

    fragColor = vec4(outRgb, src.a);
}
