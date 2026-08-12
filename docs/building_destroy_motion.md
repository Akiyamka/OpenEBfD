# Building Destroy-clip motion, measured per building

Referenced from docs/quirks.md, "Destroy (H3) debris motion is procedural."

Classification method: for every converted building scene
(`assets/converted/buildings/*/*.scn`), load `States/Destroy`, find the
`AnimationPlayer`'s `Explode` clip, and diff each track's keyframe values
against its first key. Tracks targeting an FX/attachment helper (leaf node
name starting with `_`, e.g. `_light01`, `_fire03` -- the marker convention
documented at quirks.md:1150-1182 and quirks.md:219-227) are excluded, since
those aren't building geometry. A building counts as moving only if a
non-helper track's value actually changes between keyframes -- not by
`%`-suffix naming or by house, both of which turned out not to predict it
(`HKFactoryFrigate` is static despite being a Harkonnen building;
`ATRefinery` is static despite carrying ~60 individually modeled debris
meshes -- none of them carry an animation track).

## No `States/Destroy` node, or no `Explode` clip inside it (54)

No corpse is spawned at all; the building just disappears plus its
rules-authored explosion (`BuildingDeathSequence.begin()`).

```
ATINEagleHouse, ATRefineryDock, ATWall, BeaconFlare, BirdBuilding, FRCamp,
GPSFXGreensmoke, GPSFXGreensmokeNL, GPSFXLavasmoke, GPSFXLavasmokeNL, GUPalace,
HKFlameTurret*, HKHanger, HKHelipad, HKINHammock, HKINHexhouse, HKINPyramid,
HKINRockHouse, HKINStepHouse, HKINTownhall, HKRefinery, HKRefineryDock, HKWall,
HLINElectricVent, IMBarracks, INBarrel1, INBarrel2, INBuggyWreck, INCrash,
INHarvesterWreck, INMedicalWreck, INSandCrawlerWreck, IXResCentre, IXTransport,
IXWall, ORBarracks, ORConYard, ORFactory, ORGasTurret, ORHanger, ORINSnakehouse,
OROutpost, ORPalace, ORPopUpTurret, ORRefinery, ORRefineryDock, ORSmWindtrap,
ORStarport, ORWall, PenguinRock, Seaguls, TLFleshVat, TLTransport, Whale
```

\* `HKFlameTurret` has a `States/Destroy` node, but it has no `Explode` clip.

## Explode clip present, but no geometry moves (85)

A corpse is spawned and the clip plays, but every non-FX track holds its
first keyframe's value for the whole clip -- the "ruin" pose is static.

```
AKINDrKynes, AKINNoddingDonkey, AKINSilo, AKINhungfigure, AKINhungfigure2,
AKINhungfigure3, AKINhungfigure4, ATBarracks, ATConYard, ATFactory,
ATFactoryFrigate, ATHanger, ATHelipad, ATINBrancastle, ATINHouse2, ATINHouse3,
ATINHouse4, ATINStPauls, ATINSultan, ATOutpost, ATPalace, ATPillbox, ATRefinery,
ATRocketTurret, ATSmWindtrap, ATStarport, GPINSpotlight, GUMegaCannon,
GURefinery, GUbubble, GUpyramid, Guglasstank, HKFactoryFrigate, HKINApartments,
HKINGiediRef, HKINHouse, HKINHouse2, HKINHouse3, HKINHouse5, HKINHut,
HKINMossPalace, HKINSultan, HKINTYower, HKINTennament, HKINTennament2,
HKINTrafford, HKINTwafford, HLINLighGate, HLINMHut2, HLINMhut, HLINOxygen,
IMMonument, INFRCampFire, INFRTent, INFRTent2, INGUCyclopseHouse,
INGUJackelHouse, INHouse, INIMShed, INIMShed2, INIXDome, INIXTower, INIXTower2,
INMartHouse, INMartHouse2, INPalace, INStore, INStore2, INTLWindtrap,
INWorkshop, IXMegaCannon, IXRefinery, IXWindtrap, ORFactoryFrigate,
ORINBubbleHouse, ORINIndi, ORINOuthouse, ORINTower, ORINTower2, ORINTownhall,
ORINhall, SMStarport, Ship, TLINGreenhouse, TLTurret
```

## Explode clip present and geometry actually moves (13)

At least one non-FX track's value changes across the clip's keyframes.

```
CNINATTree, CNINATTree2, CNINATTree3, CNINATTree4, GUWormhead, HKBarracks,
HKConYard, HKFactory, HKGunTurret, HKOutpost, HKPalace, HKSmWindtrap,
HKStarport
```
