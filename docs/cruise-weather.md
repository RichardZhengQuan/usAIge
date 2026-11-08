# Sailing weather renderer

The sailing scene uses a native Metal background for sky, textured clouds,
perspective ocean shading, reflections and haze, depth-layered rain and snow,
and rain impacts on the sea. The ship and its existing sailing/buoyancy model
remain a separate overlay. There are eight explicit conditions: Sunny, Cloudy,
Rain, Thunder, Storm, Typhoon, Snow and Night, plus Automatic.

Memory and Storage open one borderless resource ocean. Usage pigments are
part of the water shader itself, sharing its ripples, reflections, foam and
weather. The sky meets the same moving surface that supports the ship; there
is no separate blue sea above an overlaid usage chart. Layer proportions
define the water’s colored depths. Names and byte amounts stay on the liquid;
text can stagger horizontally across thin layers without widening their data.
Clicking the water or choosing a layer in the native controls opens its existing
details. There is no
separate sailing/usage mode. Each resource keeps its own ship choice, and its
ship cruises within the box so the full hull and masts stay in view. The rail
uses the same contained motion; neither scene exits or wraps around an edge.

In the resource window, **Automatic** follows the selected resource's observed
condition. Memory uses macOS system memory pressure: normal is Sunny, warning
is Rain, critical is Storm, and an unavailable reading is Cloudy. The measured
AI/development process footprint is not treated as free RAM or system pressure.
Storage follows actual disk headroom: more than 20% free is Sunny, at most 20%
is Cloudy, at most 10% is Rain, and at most 5% is Storm. A clearing preview
changes the ocean's layer amounts without forecasting healthier weather.
The condition is written beside the weather control. Manual choices pin their
condition until Automatic is selected again.

The narrow rail's decorative background retains its shared random Automatic
cycle: all eight conditions in a shuffled bag, each held for 90–180 seconds
with a six-second transition. These decorative rail conditions are independent
of the selected resource window. Neither view uses location forecasts.

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
The rail samples its shared automatic weather schedule; resource readings
reuse the existing monitor refresh. Neither adds a weather polling timer.
Pause and Reduce Motion hold animation, including weather blends in flight.
Resource condition changes blend over six seconds while active. The rail
rejoins its shared current weather when resumed. Hidden or covered scenes stop their clock instead of running an unseen
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

The ship stays near the horizontal centre of the scene, with a small, slow
back-and-forth drift. Drift is bounded by the complete rolled sprite envelope,
so the ship remains visible through weather changes, shaking and resizing.
Water, sails and buoyancy continue moving without a trip offscreen or a wrap.

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
