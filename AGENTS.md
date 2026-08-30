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

`tools/check_architecture.py` statically enforces the structural rules above.
It needs no container and runs in half a second. `make lint` runs it, and
`make godot-test` starts with `make lint`, so it is covered by the normal test
command — but run it directly after any refactor that moves logic between a
facade and its modules:

```bash
python3 tools/check_architecture.py   # silence and exit 0 means clean
```

Exit codes matter: **0** clean, **1** findings in the code, **2** the manifest
or the invocation is broken. A 2 means nothing was checked.

### The rule manifest

Rules are data in `tools/architecture_rules.toml`, not code. A **zone** selects
files by glob; a **rule** forbids something inside exactly one zone:

- **zone `all`** — every `scripts/**/*.gd`. Holds the module boundary rules:
  private owner access (`_unit._x`, `_facade._x`, `_owner._x`, `_source._x`),
  navigation sibling access through the facade, bare `class_name` references
  without a `preload` (see "Code rules" above for the failure this caused),
  direct `/root/Players` autoload lookups outside
  `scripts/players/autoload_lookup.gd`, and `unindexed-slice-reference` — see
  "The slice index" below.
- **zone `sim`** — `scripts/sim/**`, live since `match_clock.gd` landed there;
  `allow_empty` is gone, so an empty zone is now an error rather than a
  silently toothless glob. Holds the determinism rules for lockstep
  multiplayer: no scene tree API, no `await`,
  no tweens or timers, no signals, no frame `delta`, no unseeded RNG, no libm
  trigonometry, no `Vector*` angle methods, no wall clock, no threads. See
  `docs/architecture/network-multiplayer.md`.

Also enforced tree-wide: `own-tick-rate`, which forbids a module from
declaring a tick rate of its own. See "The simulation tick" below for why.

Both `scripts/` and `tests/` are scanned. The `all` and `sim` zones remain
runtime-only, so tests may still reach into internals except where a dedicated
tests-zone rule says otherwise.

Adding a rule is a manifest entry plus a fixture — never a code change, unless
the rule needs real analysis, in which case add a `kind` in the checker.
Every rule must carry `why` and `instead`; both are printed on a violation,
because a rule that does not say what to do instead gets worked around blindly.

### Escape hatches

A single line can be exempted:

```gdscript
return int(cos(angle) * 32768.0)  # arch-allow: sim-no-libm-math — table generation runs offline
```

The reason is mandatory (8 characters minimum) and an unknown rule id is an
error. Hatches are counted against `allow_budget` in `[settings]` — ratchet it
down as hatches are removed, never up, the same idiom as `max-file-lines` in
`.gdlintrc`. A hatch on a line that no longer violates its rule is reported as
`stale-arch-allow`, so the budget cannot quietly drift into lying about how much
is suppressed.

### The slice index

Phase 3 was built as numbered slices (`A1a`, `B3d`, `C6b`, `R2b`), and 178
comments across `scripts/`, `tests/` and `tools/` carry their justification in
one of those numbers. [`docs/architecture/slices.md`](docs/architecture/slices.md)
maps each id to the commit that made the change, its date, one clause of what it
did, and its paragraph in `network-multiplayer.md` where it has one. It is
history: a slice gets a row when it lands. What is still *owed* lives in the
`exempt` lists in the manifest, where a queued group shrinks as slices empty it.

Two checks keep it honest, split along what each tool can see:

- `unindexed-slice-reference` (kind `slice-index`) reports any `slice <id>` in
  `scripts/**/*.gd` whose id has no row. Only the `slice`/`slices` prefix makes
  a reference a reference — bare `B4` and `C5` are ordinary prose, and a rule
  that reported those would be switched off within a day. The rule sees its
  zone only, so references under `tests/` and `tools/` are not covered by it.
- `check_slice_index_hashes()` in the self-test runs `git rev-parse` over every
  hash in the table and compares each row's date against its commit. It is in
  the self-test because the checker itself touches nothing but the filesystem —
  giving it a git dependency would make its exit code depend on repository
  state rather than on source content.

**New work carries its slice id as a commit trailer**, which nothing ever asked
for before and is the reason this had to be reconstructed out of prose:

```
Slice: R5
```

Only slice commits need it. The trailer is what makes the index auditable
(`git log --format='%h %ad %s%n%b' --date=short | grep -B0 '^Slice: '`); the
ratchet that actually bites is the rule, since the first comment under
`scripts/` that says `slice R5` fails until `R5` has a row.

### The checker's own self-test

`tools/test_check_architecture.py` drives the checker over the fixtures in
`tests/architecture/*.gd.txt`. Run it if a clean result looks suspicious — a
passing self-test is what makes "no output" trustworthy. Beyond exit codes it
asserts which rule fired, that zones actually scope (the same fixture is clean
outside its zone), that every commit hash in the slice index still resolves,
and, crucially, that **every rule in the manifest has a fixture that violates
it**. A rule with no failing fixture cannot be told apart
from a rule that silently stopped matching, so the self-test fails when a new
rule arrives without one.

### Where the checks run

Three places, deliberately overlapping, so no single one has to be remembered:

- **CI** — `.github/workflows/checks.yml` runs the self-test, the checker, and
  `gdlint` (pinned to the same `gdtoolkit==4.3.4` as the container) on every push
  to `main` and every pull request. This is the gate that counts. The Godot test
  suite cannot run there: `.gitignore` excludes `assets/`, so a fresh checkout
  has no game files — `make godot-test` stays a local command.
- **pre-commit** — `tools/hooks/pre-commit`, activated per clone with
  `make install-hooks` (it points `core.hooksPath` at `tools/hooks/`, which
  also disables anything hand-written in `.git/hooks`; `make uninstall-hooks`
  reverts). It checks the **index**, not the working tree, by extracting the
  staged commit with `git checkout-index` — a commit cannot pass on the strength
  of an unstaged fix. It runs the checker's self-test only when the checker, its
  manifest or its fixtures are part of the commit, which keeps the common case
  at half a second. `git commit --no-verify` skips it.
- **Claude Code** — `.claude/settings.json` registers a `PostToolUse` hook,
  `tools/hooks/claude_post_edit.py`, which runs the checker after any Write or
  Edit under `scripts/` (or to the manifest) and feeds findings straight back
  into the agent's context. Reporting only, never a gate; it exists so a
  violation is seen where it was written rather than at commit time.

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


## The simulation tick

Gameplay advances on one integer tick at 25 Hz, never on frame `delta`.
`MatchClock` (`scripts/sim/match_clock.gd`) is the only declaration of the
rate and holds nothing but the counter; `FrameTickDriver` turns frame time
into whole ticks and is the piece the netcode replaces later.
`Match._advance_simulation_tick()` is the only caller of `MatchClock.advance()`
and drives every system in a fixed order — read its doc comment before adding
to it, because the order is part of the simulation, not a formality.

A system joins the tick one of two ways. Controller-shaped singletons get an
`advance_tick()` called directly. Per-entity systems join a group in their own
`_ready()`/`configure()` and get a `sim_tick()` from a loop over that group, so
spawning one needs no registration anywhere else — what the central function
lists is systems, never entities.

Two habits that this work paid for repeatedly:

- **Continuous is not discrete.** Countdowns, queues and damage-over-time
  belong to the tick; motion, aim and anything that visibly rides a moving
  target stays on the frame until the view layer interpolates. Splitting a
  method that does both is usually the whole task.
- **Test the wiring, not just the part.** Every tick system has a case that
  boots the real match and calls nothing itself. Unit tests of these systems
  drive `sim_tick()` by hand and stay green even when the central loop never
  reaches them — which is exactly the failure central iteration trades for, so
  it needs its own test. Prove each one by removing the loop and watching it
  fail.

## The command bus

Every player intent — a move order, a production click, selling a building,
drawing a wall line — becomes a `SimCommand` (`scripts/sim/commands/`) that
takes effect on a scheduled tick, never at the moment of the click. Four pieces,
one job each: `SimCommandBus` (`scripts/sim/command_bus.gd`) orders and
schedules, `SimCommandCodec` encodes, `CommandExecutor`
(`scripts/match/command_executor.gd`) carries out, and
`Match._advance_simulation_tick()` drains once per tick and hands the result
straight to the executor.

To add a command type: subclass `SimCommand`, claim the next free `TYPE_ID`,
register it in `SimCommandCodec._COMMAND_SCRIPTS`, and add one branch to
`CommandExecutor.execute()`. Do not restate the list of claimed ids in your new
file — that table is the registry, and `tests/sim/command_codec_run.gd` walks
`get_global_class_list()` and fails when a subclass is missing from it. Ten
copies of that list used to live in the command files; two had already rotted
into describing a dispatch that no longer existed.

Five rules, each of which cost a slice to learn:

- **The click carries input; execution decides.** Keep in the command only what
  cannot be recomputed later — where the player pointed, which entities were
  selected, which mouse button. Recompute every judgement on the execution tick,
  because a verdict formed at click time can be wrong by the time it runs: the
  target died, the cell was taken, another player got there first inside the
  input-delay window.
- **A local check may refuse to send; it may not authorize.** A click that names
  nothing — no entity, no cell — is not a game action and must submit nothing.
  Neither is a click the local state already knows is impossible, like placing a
  building on a cell the placement reports unbuildable: filter it out and answer
  immediately. That is not the duplication trap, because the filter and the
  execution-time check are the same implementation called from two places with
  two different jobs — one may only suppress, the other decides. Do not delete
  either as redundant.
- **One dispatch.** `CommandExecutor.execute()`'s `match` is the only place that
  answers "which command is this", and its default branch is a `push_error` for
  a reason. A second dispatch elsewhere means a new type registered in one and
  forgotten in the other, and the symptom is the command vanishing without a
  trace.
- **Only `CommandExecutor` turns an id into a Node.** Sim code may not hold a
  Node at all (see the architecture checks above). Commands name entities by
  the stable ids in `scripts/sim/entity_registry.gd`; the executor resolves them
  and hands Nodes onward. An id that no longer resolves is skipped silently —
  the entity died between the click and the tick, identically on every client.
- **Views are not authorities.** Mode toggles and hover previews stay local:
  they change what the next click means, not the state of the world. Never let a
  verdict computed for the player's eyes cross into execution — a placement
  preview is drawn when the player aims and is stale by the time the thing is
  built.

Two habits, both bought with defects that a green suite did not catch:

- **Audit the player-facing strings as a set, before and after.** Converting an
  intent moves `status_changed` emissions between call sites, and it is easy to
  drop one. One was dropped in a slice that was reviewed and approved, and the
  whole suite stayed green because nothing asserted on it. Collect the string
  literals mechanically, diff the two sets, and expect them identical unless you
  meant otherwise.
- **Prove a deferral test binds.** A test that pumps and then asserts the effect
  passes just as well when the click never deferred at all. Assert the *absence*
  of the effect before the pump, then check the assertion by making the handler
  execute immediately and watching it fail. Most of this phase's real defects
  were found by comparing two things that must agree — cursor against order, doc
  against measurement, status strings before against after — not by a failing
  test.

## Network latency measurement

`make measure-nagle` (`tools/measure_nagle.py` plus
`tests/net/nagle_probe_client.gd`) answers whether `TCP_NODELAY` is set on the
two links the netcode runs over. Unlike the suites in `tools/run_godot_tests.sh`
it reports rather than asserts, because it needs real sockets and real
wall-clock timing. `docs/architecture/network-multiplayer.md`, decision 6, holds
the answers it has produced so far.

Two things about it generalise to any timing measurement here, and both were
learned by getting them wrong first:

- **A timing result means nothing without a control that fails.** Every
  direction is measured three ways — a peer with the property deliberately
  wrong, one with it deliberately right, and the real thing — and the script
  reports `INCONCLUSIVE` rather than a verdict when the two controls do not
  separate. On a machine where the effect does not reproduce, a broken harness
  and a healthy transport print exactly the same reassuring output.
- **Kernel behaviour is part of the experiment, not the background.** Nagle is
  invisible against a receiver that only ever reads (Linux keeps such a socket
  in quick-ack), and it fires only once per connection against a steady stream
  (the delayed-ACK timer adapts). Both cost a rewrite of the harness: measure
  per connection, and have the receiver behave like a real client.
