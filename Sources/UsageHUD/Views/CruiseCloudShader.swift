// Adapted from "2D Clouds" by drift, 12 November 2016.
// Original: https://www.shadertoy.com/view/4tdSWr
// Source and author permission:
// https://github.com/Zygo/xscreensaver/blob/master/hacks/glx/glsl/driftclouds.glsl
//
// 2024-06-25, drift says:
// "Just posting here to say that I don't check Shadertoy very often and I
// don't get any notifications of messages here. Anyone and everyone who
// wishes to use this shader I give my permission to use it in any way that
// you choose. Credit would be nice but I won't insist on it."
//
// Metal port reference:
// https://github.com/iamEvanYT/driftwood/blob/main/BundledScenes/2D%20Clouds.driftwoodscene/main.metal
// https://github.com/iamEvanYT/driftwood/blob/main/LICENSE
//
// MIT License
// Copyright (c) 2026 iamEvan
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// MSL helpers concatenated after the host renderer's Metal includes.
/// Adaptation: share ridged/signed shape samples, limit each octave loop to
/// four, accept the scene's lighting palette, and blend into horizon haze.
enum CruiseCloudShader {
    static let source = """
    float2 cruiseCloudHash(float2 p) {
        p = float2(dot(p, float2(127.1, 311.7)),
                   dot(p, float2(269.5, 183.3)));
        return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
    }

    // drift's compact two-dimensional simplex noise supplies irregular,
    // continuous density instead of individually drawn cloud silhouettes.
    float cruiseCloudNoise(float2 p) {
        const float k1 = 0.366025404;
        const float k2 = 0.211324865;
        float2 cell = floor(p + (p.x + p.y) * k1);
        float2 a = p - cell + (cell.x + cell.y) * k2;
        float2 corner = a.x > a.y ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float2 b = a - corner + k2;
        float2 c = a - 1.0 + 2.0 * k2;
        float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
        float3 n = h * h * h * h * float3(
            dot(a, cruiseCloudHash(cell)),
            dot(b, cruiseCloudHash(cell + corner)),
            dot(c, cruiseCloudHash(cell + 1.0))
        );
        return dot(n, float3(70.0));
    }

    float2 cruiseCloudOctave(float2 p) {
        return float2(1.6 * p.x - 1.2 * p.y,
                      1.2 * p.x + 1.6 * p.y);
    }

    // At most four samples. Uniform octave counts reduce the compact rail
    // to six noise evaluations for the complete cloud pass (ten otherwise).
    float cruiseCloudFBM(float2 p, int octaves, float amplitude, float decay) {
        float result = 0.0;
        for (int octave = 0; octave < 4; ++octave) {
            if (octave >= octaves) break;
            result += cruiseCloudNoise(p) * amplitude;
            p = cruiseCloudOctave(p);
            amplitude *= decay;
        }
        return result;
    }

    float3 cruiseClouds(float2 uv, float time, float3 sky, float3 cloudLight,
                        float3 cloudShade, float coverage, float softness,
                        float compact) {
        // y is normalized to sky height: zero at the top, one at the horizon.
        // x may be aspect-adjusted by the caller and is deliberately unclipped.
        if (uv.y < 0.0 || uv.y >= 1.0) return sky;
        bool small = compact > 0.5;
        float driftTime = time * 0.03;
        float2 p = uv * float2(1.8, 1.7);
        float warp = cruiseCloudFBM(p * 0.5, small ? 2 : 3, 0.1, 0.4);
        float2 shapeUV = p - warp + driftTime;

        // Both original shape layers sample the same locations. Reusing
        // their samples preserves their different ridged/signed weights.
        float ridge = 0.0;
        float signedShape = 0.0;
        float ridgeWeight = 0.8;
        float shapeWeight = 0.7;
        int shapeOctaves = small ? 3 : 4;
        for (int octave = 0; octave < 4; ++octave) {
            if (octave >= shapeOctaves) break;
            float noise = cruiseCloudNoise(shapeUV);
            ridge += abs(ridgeWeight * noise);
            signedShape += shapeWeight * noise;
            shapeUV = cruiseCloudOctave(shapeUV) + driftTime;
            ridgeWeight *= 0.7;
            shapeWeight *= 0.6;
        }
        float shape = signedShape * (ridge + signedShape);
        float2 detailUV = p * 2.0 - warp + driftTime * 2.0;
        float detail = cruiseCloudFBM(detailUV, small ? 1 : 3, 0.4, 0.6);
        float cover = clamp(coverage, 0.0, 1.0);
        float edge = mix(0.035, 0.14, clamp(softness, 0.0, 1.0));
        float density = cover + 8.0 * shape * ridge + detail * 0.3;
        float cloud = smoothstep(0.30 - edge, 0.70 + edge, density);

        // Higher-density weather darkens the body while the smaller noise
        // layer changes its illumination. A soft edge carries extra light.
        float illumination = clamp(0.76 + detail * 0.55 - ridge * 0.22
                                   - cover * 0.12 + (1.0 - cloud) * 0.08,
                                   0.0, 1.0);
        float3 litCloud = mix(cloudShade, cloudLight, illumination);
        float horizonFade = 1.0 - smoothstep(0.80, 1.0, uv.y);
        return mix(sky, litCloud, clamp(cloud * horizonFade, 0.0, 1.0));
    }
    """
}
