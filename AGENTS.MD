# OpenEBfD Agent Notes

## Building XBF Imports

Emperor: Battle for Dune ships building model variants with suffix families:

- `H*`: high-detail building meshes and construction/damage states.
- `M*`: medium-detail LOD meshes.
- `L*`: low-detail LOD meshes.

For OpenEBfD, import only the `H*` building variants. The original game is old enough that even `H*` meshes are low-poly by modern standards, so `M*` and `L*` variants add asset and runtime complexity without meaningful value.

When implementing building converters, examples such as `ATBarracks` should use files like `at_barracks_H0.xbf`, `at_barracks_h1.xbf`, `at_barracks_h2.xbf`, `at_barracks_h3.xbf`, and `AT_barracks_HC.XbF`, and should ignore matching `*_M*` and `*_L*` files.

## Code Rules

`tools/check_architecture.sh` machine-checks the `preload` rule below, plus
module-boundary rules not repeated here (see "Architecture checks" in
`AGENTS.md` for the full list). It is not part of the test runner, so run it
yourself after moving logic between a facade and its modules.

- Dont put all logic in single file main.gd
- Prefer explicit `const XScript := preload("res://...")` over a bare reference
  to another script's `class_name` (e.g. `SomeClass.SOME_CONST`). A bare
  global-name reference hides the dependency — it won't show up when grepping
  a file for its `preload`s — and if the referenced script fails to compile
  (a deleted constant, a typo), the failure can surface as an unrelated error
  somewhere else in the project instead of a clear error at the actual
  dependency site. This bit us once: removing a constant from
  `unit_local_avoidance.gd` broke unrelated combat tests, because `unit.gd`
  referenced `UnitNavigationSystem.MoveMode.FREE` by bare global name with no
  preload, and Godot's global `class_name` table doesn't recover cleanly when
  one script in the chain fails to parse.
