# Sailing weather renderer

The sailing scene uses a native Metal background for sky, textured clouds,
perspective ocean shading, reflections and haze, depth-layered rain and snow,
and rain impacts on the sea. The ship and its existing sailing/buoyancy model
remain a separate overlay. Weather choices and activity-driven Automatic mode
keep their existing meaning.

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
The background is capped at 960 pixels on its longest side (240 for the rail),
with at most two GPU frames in flight. Covered, hidden, closed, paused and
Reduce Motion states stop the host clock. The existing CPU illustration remains
available when Metal cannot initialize. Live drawing performs no CPU readback;
readback is reserved for qualification and frozen gallery exports.

Export all six conditions at both sizes and appearances, plus looping GIFs:

```sh
USAIGE_RENDER_WEATHER=/absolute/output/path swift test --filter CruiseWeatherRender
```
