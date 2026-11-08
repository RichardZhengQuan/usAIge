# One Piece miniature fleet

The paperweights offer 47 procedural, stylized fan-art miniatures and retain
the 12 classic ships. These are small SceneKit interpretations, not scans or
screen-accurate replicas. No external model downloads or network requests are
needed. Each paperweight remembers its own selection, which also appears in
the rail. Tall and wide models are fitted against the complete roll envelope.

| Menu | Ships |
| --- | --- |
| Straw Hats | Going Merry, Thousand Sunny, Mini Merry II, Shark Submerge III |
| Emperors & legends | Oro Jackson, Moby Dick, Red Force, Saber of Xebec, Blackbeard’s log raft, Queen Mama Chanter, Big Top, Big Top Blaster, Mammoth, Snapper Head, Piece of Spadille, Striker |
| Worst Generation | Polar Tang, Victoria Punk, Jewelry Margherita, Grudge Dolph, Liberal Hind, Stay Tune, Hanjomaru, Nostra Castello |
| Straw Hat Grand Fleet | Going Luffy-senpai, Sleeping White Horse of the Forest, Yonta Maria, Naglfar, Usoland |
| East Blue | Miss Love Duck, Bezan Black, Dreadnaught Sabre, Shark Superb, Baratie |
| Grand Line & beyond | Perfume Yuda, Numancia Flamingo, Thriller Bark, Hitsugibune, Sexy Foxy, Great Eirik, Ark Maxim, Flying Dutchman, Noah, Wind Granma |
| Navy & kingdoms | Garp’s dog-head warship, Marine battleship, Germa 66 castle ship |

The last three names describe vessel types; they are not invented canonical
proper names. The original spectral Flying Dutchman remains in Classic ships,
separate from the One Piece vessel. Some vessels have limited published views,
so unseen details are interpreted.

Reference indexes: [ship names](https://onepiece.fandom.com/wiki/Category:Ships),
[crew mappings](https://www.hellominju.com/2021/05/ONEPIECE-SHIP.html), and
[vessel silhouettes](https://www.volonte-d.com/navires/navirespirates.php).

To render the meshes individually and as a contact sheet on a Mac with Metal:

```sh
USAIGE_RENDER_FLEET=/absolute/output/path swift test --filter OnePieceFleetRender
```

The render check rejects empty snapshots and identical rendered models.
Existing paperweight tests verify every choice's persistence and full rolled
bounds; the rail render check covers every miniature at its actual display size.

## Model detail

The fleet uses curved, tapered hull meshes with a planked sheer deck, raised
wales, shaped rails and stanchions. Billowed sails have shaped feet, fabric
folds, panel seams and bolt ropes; their complete assemblies follow the wind.
Masts carry stays, shrouds, ratlines and crow’s nests. Cabin galleries, framed
ports, gun carriages, hatches and machinery vary by vessel.

The most recognizable forms are modeled separately: Merry’s two masts and
spiral-horned ram, Sunny’s lion and Soldier Dock, Moby Dick’s integrated whale
jaw, and Polar Tang’s two-level bridge. These remain stylized interpretations.
The original twelve ships retain their detailed hulls, fittings and moving parts.

Official model-kit photographs informed these four vessels’ silhouettes:
[Going Merry](https://www.bandaispirits.co.jp/products/search/detail.php?grp_id=5325&prd_id=4543112655097000),
[Thousand Sunny](https://www.bandaispirits.co.jp/products/search/detail.php?grp_id=5325&prd_id=4543112752970000),
[Polar Tang](https://www.bandaispirits.co.jp/products/search/detail.php?grp_id=5325&prd_id=4543112752987000), and
[Moby Dick](https://www.bandaispirits.co.jp/products/search/detail.php?grp_id=5325&prd_id=4543112764942000).
No kit images or external model assets are bundled.

Export individual models, the flagship overview, a full fleet sheet and
multi-angle detail renders, with mesh/resource metrics:

```sh
USAIGE_RENDER_SHIP_DETAILS=/absolute/output/path swift test --filter ShipCraftRender
```

## Direction and artwork

Ships use +X for the bow, −X for the stern, +Y for up and Z across the beam.
Square cloth, its yard and running lines share a braced assembly across the
beam. Fore-and-aft triangular and junk sails retain their own mounting.
Sunny’s lion mane and facial features face the bow; lateral animal eyes and
stern-facing decorations keep their anatomical direction.

Canvas artwork uses top-left image coordinates. Custom cloth meshes map their
geometric foot to texture V=1 and their head to V=0, matching SceneKit planes.
The back of physical cloth mirrors horizontally while remaining upright.
Orientation tests render asymmetric markers and actual Straw Hat sail artwork
from both sides, and check the forward lion, square yards and mechanical axes.

```sh
swift test --filter ShipOrientation
```

The detail export also writes bow and opposite-side views for every model,
plus five viewing angles and two poses for each of the four flagships.

## Animation

All 59 choices, including the classic ships, have rigged moving parts. Shared
wind motion drives sails and flags; vessel details add nodding figureheads,
rowing oars, rotating screws, paddle wheels, radar and flying-ark rotors,
slithering serpents, pulsing flames and candles, and drifting funnel steam.
The hull keeps following the existing liquid simulation.

One scene clock runs at 60 Hz during liquid/camera motion and 15 Hz for settled
ship parts. Decorative frames leave settled water and liquid geometry alone.
Visibility and Reduce Motion stop the clock and restore the rest pose. The rail
uses 20 cached poses per four-second cycle while hovered and visible, retaining
at most eight sprite strips and 128 static images. No renderer is retained by
the rail cache. Animated bounds are checked throughout the pose cycle and roll.

To export and verify a looping GIF for every ship plus a representative sheet:

```sh
USAIGE_RENDER_SHIP_ANIMATIONS=/absolute/output/path swift test --filter ShipAnimationRender
```

This checks rendered pixel changes at multiple phases, including the original
ships, and writes a JSON verification receipt alongside the GIFs.
