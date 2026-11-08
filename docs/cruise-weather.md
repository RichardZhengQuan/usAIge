# Sailing weather renderer

The sailing scene uses a native Metal background for sky, textured clouds,
perspective ocean shading, reflections and haze, depth-layered rain and snow,
and rain impacts on the sea. The ship and its existing sailing/buoyancy model
remain a separate overlay. There are eight explicit conditions: Sunny, Cloudy,
Rain, Thunder, Storm, Typhoon, Snow and Night, plus Automatic.

Select **Automatic** to enable a shared random weather cycle in the window and
rail. The cycle draws from a shuffled bag containing all eight conditions,
including Thunder and Typhoon, before reshuffling. Consecutive conditions never
repeat, including across bag boundaries. Each condition holds for a random
90–180 seconds, then the sky and water blend into the next condition over six
seconds. Manual choices pin their condition until Automatic is selected again.
All conditions are decorative scenes, not location forecasts or AI activity
indicators.

Thunder adds sparse, distant lightning without sound. Typhoon combines rotating
cloud and rain bands with windblown spray, crest foam and the strongest sea
profile. Pause and Reduce Motion disable lightning; Reduce Motion also restores
still ship poses. Frozen gallery exports disable lightning too.

Cloud density adapts drift's **2D Clouds** shader through the Driftwood Metal
port. This is layered procedural cloud texture, not a volumetric simulation.
The adaptation shares noise work and limits octaves for the small background.
The ocean and precipitation shader is local project code.

Sources and attribution:

- [Original shader](https://www.shadertoy.com/view/4tdSWr)
- [Original author permission preserved by XScreenSaver](https://github.com/Zygo/xscreensaver/blob/master/hacks/glx/glsl/driftclouds.glsl)
- [Driftwood Metal port](https://github.com/iamEvanYT/driftwood/blob/main/BundledScenes/2D%20Clouds.driftwoodscene/main.metal)
- [Driftwood MIT license](https://github.com/iamEvanYT/driftwood/blob/main/LICENSE)
- [Apple MetalKit drawing model](https://developer.apple.com/documentation/metalkit/mtkview)

Attribution and permission notices live in `CruiseCloudShader.swift` and ship
with the application under `Resources/ThirdPartyNotices/DriftClouds.txt`.

The existing host owns the only drawing clock: 24 Hz for the large scene and
12 Hz for the rail. MetalKit is paused and draws explicitly from that clock.
The same scene clocks sample one shared automatic weather schedule; cycling
adds no timer. Pause and Reduce Motion hold that scene’s exact weather mixture,
including any blend in flight. On resume it blends into the shared current
weather. Hidden or covered scenes stop their clock instead of running an unseen
weather loop.
The background is capped at 960 pixels on its longest side (240 for the rail),
with at most two GPU frames in flight. Covered, hidden, closed, paused and
Reduce Motion states stop the host clock. The existing CPU illustration remains
available when Metal cannot initialize. Live weather frames perform no CPU
readback; weather readback is reserved for qualification and frozen gallery
exports.

All 59 ship choices retain their animated parts. The sailing overlay and rail
miniatures share a cache of 20 sprite poses per four-second cycle, retaining
images rather than a ship renderer between frames. Each sprite preserves its
aspect ratio within 512 pixels per dimension. Still images are limited to
16 MiB and 128 entries; animation strips to 32 MiB and eight entries. The sailing
ship animates only while its scene clock is running and visible; rail miniatures
animate while hovered and visible.

The shader and buoyancy model share a sea profile for each condition:

| Weather | Scene and water response |
| --- | --- |
| Sunny | Gentle rolling waves, warm broken sun glints, no whitecaps |
| Cloudy | Broader rolling swell and muted sky reflections |
| Rain | Faster wind ripples and expanding droplet impact rings |
| Thunder | Sparse distant lightning over rainy water, with stronger swell than Rain |
| Storm | Stronger, choppier swells and crest foam |
| Typhoon | Rotating cloud and rain bands, spray and foam, and the strongest, fastest swells |
| Snow | Slower, quieter cold-colored water |
| Night | Calm low swells and restrained moon reflections |

Water tests sample the actual buoyancy surface across the scene, check the
weather ordering of swell strength, and verify afloat limits after shaking.

Export all eight conditions at both sizes and appearances, plus looping GIFs:

```sh
USAIGE_RENDER_WEATHER=/absolute/output/path swift test --filter CruiseWeatherRender
```
