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
