import Foundation

/// Original procedural sky, water, and precipitation. The renderer prepends
/// Metal's standard library and CruiseCloudShader.source to this source.
enum CruiseWeatherShader {
    static let source = """
    struct WeatherUniforms {
        float2 resolution;
        float time;
        uint weather;
        float dark;
        float compact;
        float2 padding;
        float4 sea;
    };

    struct CruiseWeatherRaster {
        float4 position [[position]];
    };

    vertex CruiseWeatherRaster cruiseWeatherVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = {float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)};
        CruiseWeatherRaster result;
        result.position = float4(positions[vertexID], 0.0, 1.0);
        return result;
    }

    float cwHash(float2 p) {
        float3 q = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    float2 cwHash2(float2 p) {
        return float2(cwHash(p + float2(11.7, 3.2)), cwHash(p + float2(37.1, 19.4)));
    }

    float3 cwSky(float2 uv, constant WeatherUniforms &u, float horizon) {
        float aspect = u.resolution.x / max(1.0, u.resolution.y);
        float skyY = saturate(uv.y / horizon);
        float3 zenith = float3(0.29, 0.61, 0.85);
        float3 haze = float3(0.78, 0.89, 0.89);
        float3 cloudLight = float3(1.0, 0.98, 0.93);
        float3 cloudShade = float3(0.58, 0.71, 0.81);
        float coverage = 0.29;
        float softness = 0.18;
        if (u.weather == 1u) {
            zenith = float3(0.43, 0.59, 0.69); haze = float3(0.77, 0.83, 0.83);
            cloudLight = float3(0.92, 0.95, 0.94); cloudShade = float3(0.49, 0.59, 0.65);
            coverage = 0.67;
        } else if (u.weather == 2u) {
            zenith = float3(0.22, 0.36, 0.47); haze = float3(0.53, 0.65, 0.69);
            cloudLight = float3(0.67, 0.76, 0.79); cloudShade = float3(0.26, 0.37, 0.46);
            coverage = 0.80; softness = 0.21;
        } else if (u.weather == 3u) {
            zenith = float3(0.105, 0.17, 0.25); haze = float3(0.36, 0.46, 0.53);
            cloudLight = float3(0.49, 0.58, 0.64); cloudShade = float3(0.13, 0.21, 0.30);
            coverage = 0.91; softness = 0.24;
        } else if (u.weather == 4u) {
            zenith = float3(0.49, 0.64, 0.76); haze = float3(0.82, 0.88, 0.91);
            cloudLight = float3(0.95, 0.97, 0.99); cloudShade = float3(0.58, 0.68, 0.78);
            coverage = 0.65; softness = 0.24;
        } else if (u.weather == 5u) {
            zenith = float3(0.025, 0.045, 0.105); haze = float3(0.16, 0.23, 0.34);
            cloudLight = float3(0.35, 0.43, 0.55); cloudShade = float3(0.065, 0.10, 0.18);
            coverage = 0.28;
        }

        // Appearance dims daylight without replacing the selected weather.
        float dim = u.dark * (u.weather == 5u ? 0.08 : 0.42);
        zenith *= 1.0 - dim;
        haze *= 1.0 - dim * 0.65;
        cloudLight *= 1.0 - dim * 0.65;
        cloudShade *= 1.0 - dim * 0.50;
        float3 sky = mix(zenith, haze, pow(skyY, 1.55));

        float2 lightPosition = float2(0.77, horizon * 0.30);
        float2 lightOffset = float2((uv.x - lightPosition.x) * aspect, uv.y - lightPosition.y);
        float radius = u.weather == 5u ? 0.022 : 0.027;
        float distanceToLight = length(lightOffset);
        float disc = 1.0 - smoothstep(radius * 0.94, radius * 1.05, distanceToLight);
        float glow = exp(-distanceToLight * (u.weather == 5u ? 17.0 : 10.0));
        float lightVisibility = (u.weather == 0u || u.weather == 5u) ? 1.0 : (u.weather == 1u ? 0.21 : 0.035);
        float3 lightColor = u.weather == 5u ? float3(0.79, 0.88, 0.98) : float3(1.0, 0.88, 0.62);
        sky += lightColor * glow * lightVisibility * (u.weather == 5u ? 0.11 : 0.23);
        sky = mix(sky, lightColor, disc * lightVisibility * 0.94);

        if (u.weather == 5u) {
            // One sparse star per cell, with stable positions and slow twinkle.
            float2 starSpace = float2(uv.x * aspect, uv.y) * 92.0;
            float2 cell = floor(starSpace);
            float2 local = fract(starSpace) - (0.18 + cwHash2(cell) * 0.64);
            float seed = cwHash(cell + 5.7);
            float star = exp(-dot(local, local) * 480.0) * step(0.973, seed);
            star *= (0.62 + 0.38 * sin(u.time * 1.1 + seed * 101.0)) * (1.0 - smoothstep(0.55, 0.95, skyY));
            sky += float3(0.72, 0.83, 1.0) * star * 0.78;
        }

        float cloudTime = u.time * (u.weather == 3u ? 1.9 : 1.0);
        sky = cruiseClouds(float2(uv.x * aspect, skyY), cloudTime, sky,
                           cloudLight, cloudShade, coverage, softness, u.compact);
        return sky;
    }

    // Six directional waves form a continuous surface. Analytic slopes produce
    // the normal; perspective footprint filtering removes horizon shimmer.
    float3 cwWaveField(float2 p, float time, float rough, float compact) {
        const float2 directions[6] = {
            float2(0.91, 0.41), float2(-0.69, 0.72), float2(0.30, 0.95),
            float2(0.98, -0.20), float2(-0.87, -0.49), float2(0.62, 0.78)
        };
        const float frequencies[6] = {0.65, 1.13, 2.05, 3.9, 7.4, 13.1};
        const float amplitudes[6] = {0.53, 0.28, 0.145, 0.070, 0.028, 0.012};
        float3 result = 0.0;
        float footprint = length(fwidth(p));
        for (uint i = 0u; i < 6u; ++i) {
            float frequency = frequencies[i];
            float filter = 1.0 / (1.0 + footprint * frequency * 1.3);
            if (compact > 0.5 && i == 5u) { filter = 0.0; }
            float amplitude = amplitudes[i] * filter * (0.18 + rough * 1.50);
            float phase = dot(p, directions[i]) * frequency - time * (0.65 + sqrt(frequency) * 0.78) * (0.8 + rough * 0.65);
            phase += result.x * 0.46;
            float wave = sin(phase), slope = cos(phase) * frequency * amplitude;
            result.x += wave * amplitude;
            result.yz += directions[i] * slope;
        }
        return result;
    }

    float cwRainImpacts(float2 world, float time, float depth) {
        float impacts = 0.0;
        for (uint layer = 0u; layer < 2u; ++layer) {
            float2 p = world * (0.67 + float(layer) * 0.37) + float(layer) * 15.3;
            float2 cell = floor(p), center = 0.23 + cwHash2(cell) * 0.54;
            float age = fract(time * (0.95 + float(layer) * 0.37) + cwHash(cell + 9.3));
            float radius = age * 0.34;
            float d = abs(length(fract(p) - center) - radius);
            float aa = max(0.007, fwidth(d) * 0.8);
            float ring = 1.0 - smoothstep(aa, aa * 2.1, d);
            impacts += ring * pow(1.0 - age, 2.0) * smoothstep(0.07, 0.55, depth);
        }
        return impacts;
    }

    float3 cwOcean(float2 uv, constant WeatherUniforms &u, float horizon) {
        float aspect = u.resolution.x / max(1.0, u.resolution.y);
        float depth = saturate((uv.y - horizon) / (1.0 - horizon));
        float perspective = 1.0 / (depth + 0.065);
        float2 world = float2((uv.x - 0.5) * aspect * 2.6, 3.3) * perspective;
        float rough = u.sea.x;
        float3 field = cwWaveField(world, u.time * u.sea.y, rough, u.compact);
        float3 normal = normalize(float3(-field.y * u.sea.z, 1.0, -field.z * u.sea.z));
        float3 view = normalize(float3((0.5 - uv.x) * aspect * 1.1, 0.12 + depth * 0.72, -1.2));
        float3 reflection = reflect(-view, normal);
        float2 reflectedUV = float2(0.5 + reflection.x * 0.62,
                                   horizon * (1.0 - saturate(reflection.y * 1.45)));
        float3 reflectedSky = cwSky(reflectedUV, u, horizon);

        float3 deep = float3(0.025, 0.29, 0.40);
        float3 shallow = float3(0.12, 0.47, 0.56);
        if (u.weather == 1u) { deep = float3(0.13, 0.30, 0.38); shallow = float3(0.30, 0.48, 0.53); }
        if (u.weather == 2u) { deep = float3(0.07, 0.21, 0.30); shallow = float3(0.23, 0.39, 0.45); }
        if (u.weather == 3u) { deep = float3(0.045, 0.13, 0.21); shallow = float3(0.16, 0.28, 0.35); }
        if (u.weather == 4u) { deep = float3(0.16, 0.32, 0.43); shallow = float3(0.39, 0.55, 0.63); }
        if (u.weather == 5u) { deep = float3(0.025, 0.075, 0.15); shallow = float3(0.08, 0.17, 0.28); }
        float3 base = mix(shallow, deep, pow(depth, 0.55)) * (1.0 - u.dark * 0.25);
        float fresnel = 0.025 + 0.975 * pow(1.0 - saturate(dot(normal, view)), 5.0);
        float3 water = mix(base, reflectedSky, 0.12 + fresnel * 0.78);
        water *= 0.87 + 0.13 * saturate(normal.y);

        // The changing normal breaks the reflected disc into small moving
        // glints; there is no painted stripe running down the sea.
        float3 light = normalize(float3(0.27 * aspect * 1.1, 0.70, 1.2));
        float3 halfVector = normalize(light + view);
        float visibility = (u.weather == 0u || u.weather == 5u) ? 1.0 : (u.weather == 1u ? 0.18 : 0.035);
        float glint = pow(saturate(dot(normal, halfVector)), mix(190.0, 85.0, rough));
        float3 glintColor = u.weather == 5u ? float3(0.50, 0.67, 0.91) : float3(1.0, 0.85, 0.56);
        water += glintColor * glint * visibility * (u.weather == 5u ? 0.55 : 1.10);
        float crest = smoothstep(0.30, 0.95, field.x) * saturate(abs(field.y + field.z) * 0.8);
        float foam = crest * u.sea.w * smoothstep(0.0, 0.18, depth);
        water = mix(water, float3(0.65, 0.76, 0.78), saturate(foam * 0.64));

        if (u.weather == 2u || u.weather == 3u) {
            float impacts = cwRainImpacts(world, u.time, depth);
            water += float3(0.26, 0.40, 0.46) * impacts * (u.weather == 3u ? 0.16 : 0.11);
        }
        // Exactly y=1 takes the cloud helper's cheap haze-only return path.
        float3 horizonHaze = cwSky(float2(uv.x, horizon), u, horizon);
        return mix(horizonHaze, water, smoothstep(0.0, 0.11, depth));
    }

    float cwRain(float2 uv, constant WeatherUniforms &u) {
        float aspect = u.resolution.x / max(1.0, u.resolution.y);
        float storm = u.weather == 3u ? 1.0 : 0.0;
        float rain = 0.0;
        for (uint layer = 0u; layer < 3u; ++layer) {
            float near = float(layer) / 2.0;
            float cells = mix(64.0, 21.0, near);
            float slant = mix(0.10, 0.31, storm);
            float2 p = float2(uv.x * aspect + uv.y * slant, uv.y) * float2(cells, cells * 0.55);
            float columnSpeed = 0.72 + 0.56 * cwHash(float2(floor(p.x), float(layer) + 17.0));
            p.y -= u.time * mix(11.0, 20.0, near) * columnSpeed * (1.0 + storm * 0.55);
            float2 cell = floor(p), seed = cwHash2(cell + float(layer) * 27.8);
            float2 local = fract(p) - float2(0.16 + seed.x * 0.68, 0.12 + seed.y * 0.76);
            float aa = max(0.007, fwidth(p.x));
            float width = mix(0.013, 0.025, near);
            float streak = 1.0 - smoothstep(width, width + aa, abs(local.x));
            float length = mix(0.31, 0.68, near) * (0.65 + seed.y * 0.65);
            streak *= 1.0 - smoothstep(length * 0.34, length * 0.55, abs(local.y));
            streak *= 0.45 + 0.55 * saturate(local.y / length + 0.5);
            rain += streak * step(seed.y, mix(0.48, 0.82, storm)) * mix(0.12, 0.30, near);
        }
        return saturate(rain);
    }

    float cwSnow(float2 uv, constant WeatherUniforms &u) {
        float aspect = u.resolution.x / max(1.0, u.resolution.y);
        float snow = 0.0;
        for (uint layer = 0u; layer < 3u; ++layer) {
            float near = float(layer) / 2.0;
            float cells = mix(39.0, 13.0, near);
            float2 p = float2(uv.x * aspect, uv.y) * cells;
            p.y -= u.time * mix(0.75, 1.9, near);
            p.x += sin(u.time * 0.46 + p.y * 0.19) * (0.13 + near * 0.30);
            p.x += sin(u.time * 0.23 + float(layer) * 2.7) * 0.35;
            float2 cell = floor(p), seed = cwHash2(cell + float(layer) * 41.3);
            float2 local = fract(p) - (0.2 + seed * 0.6);
            float radius = mix(0.026, 0.082, near) * (0.65 + seed.x * 0.8);
            float2 blurShape = local * float2(1.0, 0.92 - near * 0.12);
            float softRadius = max(radius, fwidth(p.x) * 0.70);
            float flake = exp(-dot(blurShape, blurShape) / (softRadius * softRadius) * 2.0);
            snow += flake * step(mix(0.78, 0.64, near), seed.y) * mix(0.29, 0.67, near);
        }
        return saturate(snow);
    }

    fragment float4 cruiseWeatherFragment(CruiseWeatherRaster in [[stage_in]],
                                           constant WeatherUniforms &u [[buffer(0)]]) {
        float2 uv = in.position.xy / max(u.resolution, float2(1.0));
        float horizon = mix(0.40, 0.58, step(0.5, u.compact));
        float3 color = uv.y < horizon ? cwSky(uv, u, horizon) : cwOcean(uv, u, horizon);
        if (u.weather == 2u || u.weather == 3u) {
            float rain = cwRain(uv, u);
            color = mix(color, float3(0.69, 0.80, 0.88), rain * 0.66);
        } else if (u.weather == 4u) {
            float snow = cwSnow(uv, u);
            color = mix(color, float3(0.96, 0.98, 1.0), snow);
        }
        return float4(saturate(color), 1.0);
    }
    """
}
