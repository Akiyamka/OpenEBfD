#!/usr/bin/env python3
"""Self-test for tools/check_architecture.py.

Three things are verified, in increasing order of importance:

1.  each rule in the manifest still fires on a fixture that violates it, and
    stays quiet on the fixture that does not;
2.  zones actually scope — the same fixture is clean outside its zone;
3.  **every rule in the manifest is covered by a case here**. A rule with no
    failing fixture is indistinguishable from a rule that silently stopped
    matching, which is the specific way checkers like this rot.

Fixtures are the `tests/architecture/*.gd.txt` files. Each case copies a few of
them into a throwaway tree at chosen paths, runs the checker against the real
manifest, and asserts the exit code plus what the report says.
"""

from __future__ import annotations

import dataclasses
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
CHECKER = TOOLS / "check_architecture.py"
RULES = TOOLS / "architecture_rules.toml"
FIXTURES = ROOT / "tests" / "architecture"

sys.dont_write_bytecode = True
sys.path.insert(0, str(TOOLS))
import check_architecture  # noqa: E402  (path shim above is deliberate)

EXIT_CLEAN = check_architecture.EXIT_CLEAN
EXIT_FINDINGS = check_architecture.EXIT_FINDINGS
EXIT_BROKEN_CONFIG = check_architecture.EXIT_BROKEN_CONFIG

RULE_BLOCK = """
[[rules]]
id = "no-foo"
zone = "all"
pattern = 'foo'
summary = "summary"
why = "why"
instead = "instead"
"""

MINIMAL_MANIFEST = (
    """
[settings]
allow_budget = 0

[zones.all]
include = ["scripts/**/*.gd"]
"""
    + RULE_BLOCK
)


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    files: dict[str, str] = dataclasses.field(default_factory=dict)
    expect_exit: int = EXIT_CLEAN
    expect_rules: tuple[str, ...] = ()
    expect_text: tuple[str, ...] = ()
    forbid_rules: tuple[str, ...] = ()
    allow_budget: int | None = None
    manifest: str | None = None


def sim(fixture: str) -> dict[str, str]:
    return {f"scripts/sim/{fixture}.gd": fixture}


def scripts(fixture: str) -> dict[str, str]:
    return {f"scripts/{fixture}.gd": fixture}


CASES: tuple[Case, ...] = (
    # -- module boundary rules ------------------------------------------------
    Case("clean tree", scripts("clean")),
    Case(
        "private owner access",
        scripts("private_owner_access"),
        EXIT_FINDINGS,
        expect_rules=("private-owner-access",),
        expect_text=("widen the owner's public API",),
    ),
    Case(
        "facade sibling access",
        scripts("facade_sibling_access"),
        EXIT_FINDINGS,
        expect_rules=("facade-sibling-access",),
    ),
    Case(
        "bare class_name reference behind a commented preload",
        {
            "scripts/foo_thing.gd": "foo_thing",
            "scripts/bare_class_comment_preload.gd": "bare_class_comment_preload",
        },
        EXIT_FINDINGS,
        expect_rules=("bare-class-name-reference",),
        expect_text=("FooThing",),
    ),
    Case(
        "direct autoload lookup",
        scripts("direct_autoload"),
        EXIT_FINDINGS,
        expect_rules=("direct-autoload-lookup",),
    ),
    Case(
        "autoload lookup is exempt in autoload_lookup.gd",
        {"scripts/players/autoload_lookup.gd": "direct_autoload"},
        EXIT_CLEAN,
    ),
    Case(
        "module declares its own tick rate",
        scripts("own_tick_rate"),
        EXIT_FINDINGS,
        expect_rules=("own-tick-rate",),
    ),
    Case(
        # NAVIGATION_TICK_RATE was this exact shape and the original pattern
        # (TICKS_PER_SECOND only) missed it -- this proves the _TICK_RATE
        # spelling is now caught too.
        "module declares its own tick rate via a _TICK_RATE suffix",
        scripts("own_tick_rate_suffix"),
        EXIT_FINDINGS,
        expect_rules=("own-tick-rate",),
    ),
    Case(
        # RuleTicks rather than MatchClock: the fixture's own advance(delta)
        # would trip the sim zone's frame-delta rule if it were placed under
        # scripts/sim/, which would prove nothing about this exemption.
        "the tick rate is allowed where RuleTicks owns it",
        {"scripts/rules/rule_ticks.gd": "own_tick_rate"},
        EXIT_CLEAN,
    ),
    Case(
        "simulation completed from an animation signal",
        scripts("animation_completes_simulation"),
        EXIT_FINDINGS,
        expect_rules=("animation-completes-simulation",),
    ),
    Case(
        # The exempt list in architecture_rules.toml is phase 4's audit
        # backlog, not a blessing -- this proves an entry on it really does
        # silence the rule, so that deleting one is a meaningful event.
        "the animation handler is allowed where phase 4 still owes an audit",
        {"scripts/units/unit_locomotion.gd": "animation_completes_simulation"},
        EXIT_CLEAN,
    ),
    Case(
        "zone globs reach nested directories",
        {"scripts/units/navigation/ground/deep.gd": "private_owner_access"},
        EXIT_FINDINGS,
        expect_rules=("private-owner-access",),
    ),
    Case(
        "global_position written directly instead of through SimEntityState",
        scripts("global_position_bypasses_store"),
        EXIT_FINDINGS,
        expect_rules=("global-position-bypasses-store",),
        expect_text=("set_simulation_position",),
    ),
    Case(
        # architecture_rules.toml's exempt list for this rule is the honest
        # backlog of legitimate direct writers C2 left in place (buildings,
        # cosmetic effects, the camera, and Unit.set_simulation_position()'s
        # own mirror-write) -- this proves an entry on it really does silence
        # the rule, the same shape the animation-completes-simulation case
        # pair above proves for its own exempt list, so that removing an
        # entry here is a meaningful event too.
        "the direct write is allowed where the exempt list already covers it",
        {"scripts/units/unit.gd": "global_position_bypasses_store"},
        EXIT_CLEAN,
    ),
    Case(
        # Slice R2 widened this rule's pattern from `global_position` to
        # `global_(?:position|transform)`. MatchSnapshot._restore_entities()
        # had been writing the second spelling since before C2 and the rule
        # could not see it, which is the whole argument for the widening.
        "global_transform is the same write under a second spelling",
        scripts("global_transform_bypasses_store"),
        EXIT_FINDINGS,
        expect_rules=("global-position-bypasses-store",),
    ),
    Case(
        # The partition between the write rule and R2's read rule: a qualified
        # write, in all three spellings the write rule matches, must be
        # reported by the write rule and by that rule ONLY. A read rule that
        # also fired here would double every write finding and make its own
        # exempt list -- the R3+ queue -- lie about how much reading is left.
        "a qualified write is the write rule's alone, never reported twice",
        scripts("global_position_qualified_write"),
        EXIT_FINDINGS,
        expect_rules=("global-position-bypasses-store",),
        forbid_rules=("global-position-read-bypasses-store",),
    ),
    Case(
        "another entity's position read off the node instead of the store",
        scripts("global_position_read_bypasses_store"),
        EXIT_FINDINGS,
        expect_rules=("global-position-read-bypasses-store",),
        expect_text=("simulation_position()",),
    ),
    Case(
        # The measured half of the rule's `why`: 47 of the tree's remaining
        # reads are a node reading its own mirror, in only 7 files, and that
        # node is the one guaranteed to have written the store. The rule is
        # deliberately blind to them, so something has to prove it stays blind.
        "a node reading its own global_position is not a qualified read",
        scripts("global_position_bare_read"),
        EXIT_CLEAN,
        forbid_rules=("global-position-read-bypasses-store",),
    ),
    Case(
        # The read rule's exempt list is two lists in one: permanent view code
        # and the R3+ migration queue. This proves an entry really does
        # silence the rule -- so that deleting a queued one is a meaningful
        # event, and so that the permanent half is genuinely being scanned
        # rather than skipped by a zone that never reached it.
        "the qualified read is allowed where the exempt list already covers it",
        {"scripts/world/camera/rts_camera.gd": "global_position_read_bypasses_store"},
        EXIT_CLEAN,
    ),
    # -- simulation determinism rules ----------------------------------------
    Case(
        "scene tree API in sim",
        sim("sim_node_api"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-node-api",),
    ),
    Case("await in sim", sim("sim_await"), EXIT_FINDINGS, expect_rules=("sim-no-await",)),
    Case(
        "tween in sim",
        sim("sim_tween_or_timer"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-tween-or-timer",),
    ),
    Case(
        "signal in sim",
        sim("sim_signals"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-signals",),
    ),
    Case(
        "frame delta in sim",
        sim("sim_frame_delta"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-frame-delta",),
    ),
    Case(
        "unseeded rng in sim",
        sim("sim_global_rng"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-global-rng",),
    ),
    Case(
        "libm math in sim",
        sim("sim_libm_math"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-libm-math",),
        expect_text=("SimMath",),
    ),
    Case(
        "vector angle math in sim",
        sim("sim_vector_angle_math"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-vector-angle-math",),
    ),
    Case(
        "engine clock in sim",
        sim("sim_engine_clock"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-engine-clock",),
    ),
    Case(
        "threading primitive in sim",
        sim("sim_threads"),
        EXIT_FINDINGS,
        expect_rules=("sim-no-threads",),
    ),
    # -- zone scoping ---------------------------------------------------------
    Case(
        "sim rules do not apply outside the sim zone",
        {"scripts/units/deploy.gd": "sim_await"},
        EXIT_CLEAN,
        forbid_rules=("sim-no-await",),
    ),
    # -- escape hatches -------------------------------------------------------
    Case(
        "hatch with a reason suppresses its rule",
        sim("sim_hatch_valid"),
        EXIT_CLEAN,
        allow_budget=1,
        forbid_rules=("sim-no-libm-math",),
    ),
    Case(
        "hatch counts against the budget",
        sim("sim_hatch_valid"),
        EXIT_FINDINGS,
        allow_budget=0,
        expect_text=("budget exceeded",),
    ),
    Case(
        "hatch without a real reason is rejected",
        sim("sim_hatch_no_reason"),
        EXIT_BROKEN_CONFIG,
        expect_text=("at least 8 characters",),
    ),
    Case(
        "hatch naming an unknown rule is rejected",
        sim("sim_hatch_unknown_rule"),
        EXIT_BROKEN_CONFIG,
        expect_text=("unknown rule",),
    ),
    Case(
        "hatch that suppresses nothing is reported",
        sim("sim_hatch_stale"),
        EXIT_FINDINGS,
        allow_budget=1,
        expect_rules=("stale-arch-allow",),
    ),
    Case(
        "clean tree under budget prints a ratchet note",
        scripts("clean"),
        EXIT_CLEAN,
        allow_budget=3,
        expect_text=("ratchet `allow_budget` down to 0",),
    ),
    # -- manifest integrity ---------------------------------------------------
    Case(
        "a zone matching no files is an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST
        + '\n[zones.ghost]\ninclude = ["scripts/ghost/**/*.gd"]\n',
        expect_text=("matches no files",),
    ),
    Case(
        "a zone staged ahead of the code may be empty",
        scripts("clean"),
        EXIT_CLEAN,
        manifest=MINIMAL_MANIFEST
        + '\n[zones.ghost]\ninclude = ["scripts/ghost/**/*.gd"]\nallow_empty = true\n',
    ),
    Case(
        "a rule naming an undeclared zone is an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST.replace('zone = "all"', 'zone = "nope"'),
        expect_text=("must name a declared zone",),
    ),
    Case(
        "duplicate rule ids are an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST + RULE_BLOCK,
        expect_text=("duplicate rule id",),
    ),
    Case(
        "a mistyped rule key is an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST.replace("pattern = 'foo'", "patern = 'foo'"),
        expect_text=("unknown key",),
    ),
    Case(
        "an invalid regex is an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST.replace("pattern = 'foo'", "pattern = '([unclosed'"),
        expect_text=("invalid pattern",),
    ),
    Case(
        "require-preload takes no pattern",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST.replace(
            "pattern = 'foo'", 'kind = "require-preload"\npattern = \'foo\''
        ),
        expect_text=("takes no `pattern`",),
    ),
    Case(
        "a negative allow budget is an error",
        scripts("clean"),
        EXIT_BROKEN_CONFIG,
        manifest=MINIMAL_MANIFEST.replace("allow_budget = 0", "allow_budget = -1"),
        expect_text=("must be an integer >= 0",),
    ),
)


def run_case(case: Case) -> list[str]:
    """Run one case; return a list of human-readable failures (empty when it passes)."""
    with tempfile.TemporaryDirectory() as raw_root:
        root = Path(raw_root)
        files = dict(case.files)
        # The real manifest's [zones.sim] no longer carries `allow_empty`
        # (scripts/sim/match_clock.gd is real code now), so every case that
        # checks against the real manifest needs at least one file under
        # scripts/sim/ or the checker errors out on an empty zone before it
        # even gets to what the case is actually testing. Cases that already
        # place a fixture there (the sim-rule cases below) or that swap in
        # their own manifest (which may not declare a sim zone at all) don't
        # need the filler.
        if case.manifest is None and not any(
            destination.startswith("scripts/sim/") for destination in files
        ):
            files["scripts/sim/_zone_filler.gd"] = "sim_clean"
        for destination, fixture in files.items():
            target = root / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(FIXTURES / f"{fixture}.gd.txt", target)

        rules_path = RULES
        if case.manifest is not None:
            rules_path = root / "rules.toml"
            rules_path.write_text(case.manifest, encoding="utf-8")

        command = [sys.executable, str(CHECKER), str(root), "--rules", str(rules_path)]
        if case.allow_budget is not None:
            command += ["--allow-budget", str(case.allow_budget)]
        completed = subprocess.run(command, capture_output=True, text=True)

    output = completed.stdout + completed.stderr
    failures: list[str] = []
    if completed.returncode != case.expect_exit:
        failures.append(
            f"expected exit {case.expect_exit}, got {completed.returncode}"
        )
    for rule_id in case.expect_rules:
        if f": {rule_id}:" not in output:
            failures.append(f"expected rule `{rule_id}` in the report")
    for rule_id in case.forbid_rules:
        if f": {rule_id}:" in output:
            failures.append(f"rule `{rule_id}` should not have fired")
    for text in case.expect_text:
        if text not in output:
            failures.append(f"expected {text!r} in the report")
    if failures:
        failures.append("--- checker output ---\n" + (output.strip() or "(empty)"))
    return failures


def check_glob_translation() -> list[str]:
    """Guard the one helper whose semantics the zones silently depend on."""
    expectations = (
        ("scripts/**/*.gd", "scripts/unit.gd", True),
        ("scripts/**/*.gd", "scripts/units/air/flight.gd", True),
        ("scripts/**/*.gd", "scripts/unit.gd.txt", False),
        ("scripts/**/*.gd", "tests/unit.gd", False),
        ("scripts/sim/**/*.gd", "scripts/sim/tick.gd", True),
        ("scripts/sim/**/*.gd", "scripts/sim/units/tick.gd", True),
        ("scripts/sim/**/*.gd", "scripts/units/tick.gd", False),
        ("scripts/**/fx/**", "scripts/combat/fx/debris.gd", True),
        ("scripts/**/fx/**", "scripts/combat/debris.gd", False),
        ("scripts/players/autoload_lookup.gd", "scripts/players/autoload_lookup.gd", True),
        ("scripts/players/autoload_lookup.gd", "scripts/players/other.gd", False),
    )
    failures: list[str] = []
    for pattern, path, expected in expectations:
        actual = check_architecture.glob_to_regex(pattern).fullmatch(path) is not None
        if actual is not expected:
            failures.append(
                f"glob {pattern!r} vs {path!r}: expected {expected}, got {actual}"
            )
    return failures


def check_rule_coverage() -> list[str]:
    """Every rule in the real manifest must have a case that expects it to fire."""
    manifest = check_architecture.load_manifest(RULES)
    declared = {rule.id for rule in manifest.rules}
    covered = {rule_id for case in CASES for rule_id in case.expect_rules}
    uncovered = sorted(declared - covered)
    if uncovered:
        return [
            "rules with no failing fixture: "
            + ", ".join(uncovered)
            + ". Add a fixture in tests/architecture/ and a case in CASES — an "
            "unexercised rule cannot be told apart from a broken one."
        ]
    unknown = sorted(covered - declared - {"stale-arch-allow"})
    if unknown:
        return [f"cases expect rules that the manifest does not declare: {', '.join(unknown)}"]
    return []


def main() -> int:
    failed = 0

    for name, failures in (
        ("glob translation", check_glob_translation()),
        ("rule coverage", check_rule_coverage()),
    ):
        if failures:
            failed += 1
            print(f"FAIL {name}", file=sys.stderr)
            for failure in failures:
                print(f"  {failure}", file=sys.stderr)

    for case in CASES:
        failures = run_case(case)
        if failures:
            failed += 1
            print(f"FAIL {case.name}", file=sys.stderr)
            for failure in failures:
                print(f"  {failure}", file=sys.stderr)

    total = len(CASES) + 2
    if failed:
        print(f"\n{failed} of {total} architecture checker tests failed", file=sys.stderr)
        return 1
    print(f"architecture checker self-test: {total} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
