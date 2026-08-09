# Repository guidance

## Emperor rules data

All original Emperor: Battle for Dune rules required by this repository are
available locally. Do not search for or download rules data from external
sites.

- `assets/raw_original_content/MODEL/Rules.txt` is the raw original rules file.
  The filename is case-sensitive (`Rules.txt`). Use it when original comments,
  spelling, or source context are relevant.
- `assets/converted/rules.db` is the normalized SQLite rules database and the
  source of truth for typed/queryable rule data.
- `assets/converted/schema.sql` documents the database schema, column meanings,
  relationships, and conversion decisions. Read the relevant schema section
  before querying or changing rules-dependent behavior.
- `assets/converted/rules/` contains Godot resources exported from the database
  for runtime consumption. Treat these as generated representations, not as an
  independent rules source.

Prefer read-only `sqlite3 assets/converted/rules.db ...` queries for structured
analysis. Cross-check the corresponding entry in `Rules.txt` when units or
conversion semantics (for example comments describing units per tick/update)
matter.

## Building XBF imports

Emperor: Battle for Dune ships building model variants with suffix families:

- `H*`: high-detail building meshes and construction/damage states.
- `M*`: medium-detail LOD meshes.
- `L*`: low-detail LOD meshes.

For OpenEBfD, import only the `H*` building variants. The original game is old
enough that even `H*` meshes are low-poly by modern standards, so `M*` and `L*`
variants add asset and runtime complexity without meaningful value.

When implementing building converters, examples such as `ATBarracks` should use
files like `at_barracks_H0.xbf`, `at_barracks_h1.xbf`, `at_barracks_h2.xbf`,
`at_barracks_h3.xbf`, and `AT_barracks_HC.XbF`, and should ignore matching
`*_M*` and `*_L*` files.

## Code rules

- Don't put all logic in a single file `main.gd`.
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

The `preload` rule, along with the module boundaries described below, is
machine-checked — see "Architecture checks".

## Architecture checks

`tools/check_architecture.sh` statically enforces the structural rules above
over every `scripts/**/*.gd`. It needs no container and runs in under a second,
but it is **not** part of `tools/run_godot_tests.sh` — run it separately, in
particular after any refactor that moves logic between a facade and its
modules:

```bash
./tools/check_architecture.sh   # silence and exit 0 means clean
```

It reports, with `file:line`:

- **private owner access** — a module reaching into `_unit._x`, `_facade._x`,
  `_owner._x` or `_source._x`. Modules talk to their owner through its public
  API; if something is missing there, widen the API deliberately rather than
  reaching past it.
- **navigation sibling access through facade** — `_facade.planner`,
  `_facade.avoidance`, `_facade.registry` and the other navigation subsystems.
  A module must not use the facade as a directory of its siblings.
- **bare class_name reference** — using `SomeClass.` without an explicit
  `preload()` of that script in the same file. See "Code rules" above for why
  this one has already caused a confusing cross-suite failure.
- **direct autoload path lookup** — `get_node_or_null("/root/Players")` or
  `/root/Cursors` anywhere except `scripts/players/autoload_lookup.gd`.

Only `scripts/` is scanned; `tests/` may still reach into internals.

`tools/test_check_architecture.sh` is the checker's own self-test, driven by the
fixtures in `tests/architecture/*.gd.txt`. Run it if a clean result looks
suspicious — it verifies the checker still fails on each rule it claims to
enforce, so a passing self-test is what makes "no output" trustworthy.

## Godot container

Run commands that use `tools/godot-container` sequentially. Parallel runs share
the same container and `/workspace` mount, so they interfere with one another
and can produce invalid project-path or incomplete class-loading errors that
look like test failures.


### Running Godot from a git worktree

`.gitignore` excludes `assets/*` and `.godot`, so a fresh worktree has neither
the converted/original assets nor Godot's import cache. Both matter more than
they look like they do: without `.godot/global_script_class_cache.cfg`, every
`class_name` fails to resolve, and the resulting `Could not find type "X" in
the current scope` parse errors read like a broken change rather than a
missing cache.

Symlinking them in is not enough on its own. `tools/godot-container` mounts
only the project directory, so an absolute symlink pointing outside it dangles
inside the container — and the mount uses SELinux `:Z`, so simply adding the
target as a second volume yields `Permission denied` rather than a clear
error. Two things are needed together:

1. In the worktree, symlink `.godot` and each untracked `assets/` subtree
   (`raw_original_content`, `reworked`, and each `converted/*` directory other
   than the tracked `rules.db`/`schema.sql`) to the main checkout.
2. Run Godot with the main checkout mounted at its own host path, and SELinux
   labelling off so the symlinks resolve:

```bash
podman run --rm --userns=keep-id --security-opt label=disable \
  --volume "$PWD:/workspace" \
  --volume /path/to/main/checkout:/path/to/main/checkout \
  --workdir /workspace openebfd-godot:4.7 godot --headless --path /workspace "$@"
```

`tools/run_godot_tests.sh` takes that wrapper via `GODOT_CONTAINER` (it must
tolerate a leading `godot` argument, which the script passes). Sharing one
`.godot` between checkouts is fine — the cache is keyed by `res://` paths —
but it is another reason to keep container runs sequential.

Note that a headless run never creates `.godot` itself, so "run it once and
let it build the cache" does not work; it has to come from the main checkout.

### A headless run that "hangs" is usually a compile error, not slow work

A `godot --headless --script res://....gd` invocation for a one-shot
converter/test should finish in seconds. If it's still running after a while
with near-zero CPU, that is not "still working" — a `SceneTree` script that
throws a parse/compile error (bad type inference, a broken `preload`, etc.)
never reaches its `quit()` call, so the process falls through to Godot's idle
main loop and sits there forever doing nothing, consuming ~0% CPU. It looks
alive in `ps`/`podman ps` and gives no other external signal that anything is
wrong.

Don't pipe the run through `| tail` (or any buffering command) and then wait —
that hides `SCRIPT ERROR:`/`Parse Error:` lines until the process exits, and
since it never exits on its own, you'll wait forever with an empty buffer and
no way to tell a hang from real progress. Instead:

- Run with a bounded `timeout` and let stdout/stderr print directly (or `tee`
  to a file you can `cat` mid-run) so `SCRIPT ERROR`/`Parse Error` output is
  visible immediately, not buffered behind the process exit.
- If a background run has been alive for a while, check `ps`/`podman top` CPU%
  for that PID before continuing to wait — near-zero CPU on a script that
  should be doing real work is the signal to go read its output now rather
  than keep waiting.
- On any hang, kill it, fix the reported error, and rerun — don't assume it
  will eventually finish.

