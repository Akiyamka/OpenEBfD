#!/usr/bin/env python3
"""Static architecture checks for OpenEBfD.

Rules live as data in tools/architecture_rules.toml: a *zone* selects files by
glob, a *rule* forbids something inside one zone. This module supplies the
scanning, the escape-hatch bookkeeping and the three rule kinds a rule can ask
for:

    forbid              regex over source with comments and string bodies removed
    forbid-in-strings   regex over source with comments removed, strings kept
    require-preload     every `SomeClass.` needs a preload of its script

Findings are reported as `path:line: rule-id: summary`, so editors and CI can
jump to them, followed by indented `why`, `instead` and the offending line.

Exit codes:

    0   clean
    1   findings — violations, stale hatches, or hatch budget exceeded
    2   the rule manifest or the invocation is broken

The distinction matters: 1 means the code is wrong, 2 means the check itself is
wrong, and a check that is silently enforcing nothing is the failure mode this
whole file exists to prevent.
"""

from __future__ import annotations

import sys

# Checked before importing tomllib, which only exists from 3.11 on: a bare
# ModuleNotFoundError from CI or an older distro reads like a broken checkout.
if sys.version_info < (3, 11):
    raise SystemExit(
        "check_architecture: needs Python 3.11 or newer for tomllib, found "
        f"{sys.version.split()[0]}"
    )

import argparse  # noqa: E402  (version guard above must run first)
import dataclasses  # noqa: E402
import re  # noqa: E402
import textwrap  # noqa: E402
import tomllib  # noqa: E402
from pathlib import Path  # noqa: E402

EXIT_CLEAN = 0
EXIT_FINDINGS = 1
EXIT_BROKEN_CONFIG = 2

DEFAULT_RULES_PATH = "tools/architecture_rules.toml"
SCAN_GLOB = "scripts/**/*.gd"

RULE_KINDS = frozenset({"forbid", "forbid-in-strings", "require-preload"})

SETTINGS_KEYS = frozenset({"allow_budget", "min_reason_length"})
ZONE_KEYS = frozenset({"description", "include", "exclude", "allow_empty"})
RULE_KEYS = frozenset(
    {"id", "zone", "kind", "pattern", "exempt", "summary", "why", "instead"}
)

RULE_ID_RE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
CLASS_NAME_RE = re.compile(r"\bclass_name\s+(\w+)")
PRELOAD_RE = re.compile(r"""preload\s*\(\s*["'](res://[^"']+)["']\s*\)""")
HATCH_RE = re.compile(r"#\s*arch-allow\s*:\s*(?P<body>.+)$")
HATCH_SEPARATOR_RE = re.compile(r"\s*(?:—|–|--|:)\s*")
HATCH_IDS_RE = re.compile(r"^[a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*$")

REPORT_WIDTH = 96


class ConfigError(Exception):
    """The manifest or the invocation is unusable; nothing was checked."""


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Settings:
    allow_budget: int
    min_reason_length: int


@dataclasses.dataclass(frozen=True)
class Zone:
    name: str
    description: str
    include: tuple[re.Pattern[str], ...]
    exclude: tuple[re.Pattern[str], ...]
    allow_empty: bool

    def matches(self, relative: str) -> bool:
        if not any(pattern.fullmatch(relative) for pattern in self.include):
            return False
        return not any(pattern.fullmatch(relative) for pattern in self.exclude)


@dataclasses.dataclass(frozen=True)
class Rule:
    id: str
    zone: Zone
    kind: str
    summary: str
    why: str
    instead: str
    pattern: re.Pattern[str] | None
    exempt: tuple[re.Pattern[str], ...]

    def applies_to(self, relative: str) -> bool:
        if any(pattern.fullmatch(relative) for pattern in self.exempt):
            return False
        return self.zone.matches(relative)


@dataclasses.dataclass(frozen=True)
class Manifest:
    settings: Settings
    zones: dict[str, Zone]
    rules: tuple[Rule, ...]


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a forward-slash glob into an anchored regex.

    Written out rather than delegated to `fnmatch` or `PurePath.full_match`
    because the exact meaning of `**` is load-bearing here: `scripts/**/*.gd`
    has to match `scripts/unit.gd` as well as `scripts/units/air/flight.gd`,
    and a zone that quietly matches fewer files than intended enforces nothing.
    """
    out: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append(r"(?:[^/]+/)*")
            i += 3
        elif pattern.startswith("**", i):
            out.append(r".*")
            i += 2
        elif pattern[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out))


def _require_keys(table: dict[str, object], allowed: frozenset[str], where: str) -> None:
    unknown = sorted(set(table) - allowed)
    if unknown:
        raise ConfigError(
            f"{where}: unknown key(s) {', '.join(unknown)}; "
            f"allowed keys are {', '.join(sorted(allowed))}"
        )


def _string_list(value: object, where: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ConfigError(f"{where}: expected a list of strings")
    return tuple(value)


def _text(table: dict[str, object], key: str, where: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{where}: `{key}` is required and must be a non-empty string")
    return " ".join(value.split())


def load_manifest(path: Path) -> Manifest:
    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"rule manifest not found: {path}") from error
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"{path}: {error}") from error

    _require_keys(raw, frozenset({"settings", "zones", "rules"}), str(path))

    settings_table = raw.get("settings", {})
    _require_keys(settings_table, SETTINGS_KEYS, "[settings]")
    allow_budget = settings_table.get("allow_budget", 0)
    min_reason_length = settings_table.get("min_reason_length", 8)
    if not isinstance(allow_budget, int) or allow_budget < 0:
        raise ConfigError("[settings]: `allow_budget` must be an integer >= 0")
    if not isinstance(min_reason_length, int) or min_reason_length < 1:
        raise ConfigError("[settings]: `min_reason_length` must be an integer >= 1")
    settings = Settings(allow_budget, min_reason_length)

    zones: dict[str, Zone] = {}
    zone_tables = raw.get("zones", {})
    if not isinstance(zone_tables, dict) or not zone_tables:
        raise ConfigError("[zones]: at least one zone is required")
    for name, table in zone_tables.items():
        where = f"[zones.{name}]"
        if not isinstance(table, dict):
            raise ConfigError(f"{where}: expected a table")
        _require_keys(table, ZONE_KEYS, where)
        include = _string_list(table.get("include", []), f"{where}.include")
        if not include:
            raise ConfigError(f"{where}: `include` must list at least one glob")
        exclude = _string_list(table.get("exclude", []), f"{where}.exclude")
        allow_empty = table.get("allow_empty", False)
        if not isinstance(allow_empty, bool):
            raise ConfigError(f"{where}: `allow_empty` must be a boolean")
        zones[name] = Zone(
            name=name,
            description=" ".join(str(table.get("description", "")).split()),
            include=tuple(glob_to_regex(item) for item in include),
            exclude=tuple(glob_to_regex(item) for item in exclude),
            allow_empty=allow_empty,
        )

    rules: list[Rule] = []
    seen: set[str] = set()
    rule_tables = raw.get("rules", [])
    if not isinstance(rule_tables, list) or not rule_tables:
        raise ConfigError("[[rules]]: at least one rule is required")
    for index, table in enumerate(rule_tables):
        where = f"[[rules]] #{index + 1}"
        if not isinstance(table, dict):
            raise ConfigError(f"{where}: expected a table")
        _require_keys(table, RULE_KEYS, where)

        rule_id = table.get("id")
        if not isinstance(rule_id, str) or not RULE_ID_RE.fullmatch(rule_id):
            raise ConfigError(f"{where}: `id` must be a kebab-case identifier")
        if rule_id in seen:
            raise ConfigError(f"{where}: duplicate rule id `{rule_id}`")
        seen.add(rule_id)
        where = f"rule `{rule_id}`"

        zone_name = table.get("zone")
        if not isinstance(zone_name, str) or zone_name not in zones:
            raise ConfigError(
                f"{where}: `zone` must name a declared zone "
                f"({', '.join(sorted(zones))})"
            )

        kind = table.get("kind", "forbid")
        if kind not in RULE_KINDS:
            raise ConfigError(
                f"{where}: `kind` must be one of {', '.join(sorted(RULE_KINDS))}"
            )

        pattern_source = table.get("pattern")
        if kind == "require-preload":
            if pattern_source is not None:
                raise ConfigError(f"{where}: `require-preload` takes no `pattern`")
            pattern = None
        else:
            if not isinstance(pattern_source, str) or not pattern_source:
                raise ConfigError(f"{where}: `pattern` is required for kind `{kind}`")
            try:
                pattern = re.compile(pattern_source)
            except re.error as error:
                raise ConfigError(f"{where}: invalid pattern: {error}") from error

        rules.append(
            Rule(
                id=rule_id,
                zone=zones[zone_name],
                kind=kind,
                summary=_text(table, "summary", where),
                why=_text(table, "why", where),
                instead=_text(table, "instead", where),
                pattern=pattern,
                exempt=tuple(
                    glob_to_regex(item)
                    for item in _string_list(table.get("exempt", []), f"{where}.exempt")
                ),
            )
        )

    return Manifest(settings=settings, zones=zones, rules=tuple(rules))


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Hatch:
    relative: str
    line: int
    rule_id: str
    reason: str
    used: bool = False


@dataclasses.dataclass(frozen=True)
class Source:
    """One .gd file in the three views the rule kinds need.

    `code` and `strings` are 0-indexed lists parallel to `raw`, so line numbers
    stay comparable across all three.
    """

    path: Path
    relative: str
    raw: list[str]
    code: list[str]
    strings: list[str]
    hatches: dict[int, list[Hatch]]


def strip_source(text: str, *, keep_strings: bool) -> list[str]:
    """Remove comments, and optionally string bodies, keeping line numbering.

    Comment and string stripping is what keeps the rules honest: without it,
    every rule that bans an identifier also fires on the documentation that
    explains why it is banned.
    """
    result: list[str] = []
    in_triple: str | None = None
    for line in text.splitlines():
        out: list[str] = []
        quote: str | None = None
        escaped = False
        i = 0
        while i < len(line):
            if in_triple is not None:
                end = line.find(in_triple, i)
                if end < 0:
                    break
                i = end + 3
                in_triple = None
                continue
            if line.startswith('"""', i) or line.startswith("'''", i):
                in_triple = line[i : i + 3]
                i += 3
                continue
            char = line[i]
            if quote is not None:
                if keep_strings:
                    out.append(char)
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                i += 1
                continue
            if char in "\"'":
                quote = char
                if keep_strings:
                    out.append(char)
            elif char == "#":
                break
            else:
                out.append(char)
            i += 1
        result.append("".join(out))
    return result


def parse_hatches(
    relative: str, raw_lines: list[str], known_rules: set[str], min_reason: int
) -> dict[int, list[Hatch]]:
    hatches: dict[int, list[Hatch]] = {}
    for number, line in enumerate(raw_lines, 1):
        match = HATCH_RE.search(line)
        if match is None:
            continue
        body = match.group("body").strip()
        parts = HATCH_SEPARATOR_RE.split(body, maxsplit=1)
        if len(parts) != 2:
            raise ConfigError(
                f"{relative}:{number}: malformed hatch; expected "
                "`# arch-allow: <rule-id> — <reason>`"
            )
        ids_text, reason = parts[0].strip(), parts[1].strip()
        if not HATCH_IDS_RE.fullmatch(ids_text):
            raise ConfigError(
                f"{relative}:{number}: malformed hatch; `{ids_text}` is not a "
                "comma-separated list of rule ids"
            )
        if len(reason) < min_reason:
            raise ConfigError(
                f"{relative}:{number}: hatch reason must be at least "
                f"{min_reason} characters; a hatch without a reason is a "
                "disabled rule nobody can review"
            )
        for rule_id in (item.strip() for item in ids_text.split(",")):
            if rule_id not in known_rules:
                raise ConfigError(
                    f"{relative}:{number}: hatch names unknown rule `{rule_id}`"
                )
            hatches.setdefault(number, []).append(
                Hatch(relative=relative, line=number, rule_id=rule_id, reason=reason)
            )
    return hatches


def load_sources(root: Path, known_rules: set[str], min_reason: int) -> list[Source]:
    sources: list[Source] = []
    for path in sorted(root.glob(SCAN_GLOB)):
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        raw = text.splitlines()
        sources.append(
            Source(
                path=path,
                relative=relative,
                raw=raw,
                code=strip_source(text, keep_strings=False),
                strings=strip_source(text, keep_strings=True),
                hatches=parse_hatches(relative, raw, known_rules, min_reason),
            )
        )
    return sources


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Finding:
    relative: str
    line: int
    rule_id: str
    summary: str
    why: str
    instead: str
    code: str

    @property
    def sort_key(self) -> tuple[str, int, str]:
        return (self.relative, self.line, self.rule_id)


def _detail(label: str, text: str) -> str:
    prefix = f"    {label:<8} "
    return textwrap.fill(
        text,
        width=REPORT_WIDTH,
        initial_indent=prefix,
        subsequent_indent=" " * len(prefix),
    )


def render(finding: Finding) -> str:
    head = f"{finding.relative}:{finding.line}: {finding.rule_id}: {finding.summary}"
    body = [_detail("why", finding.why), _detail("instead", finding.instead)]
    if finding.code:
        body.append(_detail("code", finding.code))
    return "\n".join([head, *body])


def _forbid(rule: Rule, sources: list[Source]) -> list[Finding]:
    findings: list[Finding] = []
    assert rule.pattern is not None
    for source in sources:
        lines = source.code if rule.kind == "forbid" else source.strings
        for number, line in enumerate(lines, 1):
            if rule.pattern.search(line):
                findings.append(
                    Finding(
                        relative=source.relative,
                        line=number,
                        rule_id=rule.id,
                        summary=rule.summary,
                        why=rule.why,
                        instead=rule.instead,
                        code=line.strip(),
                    )
                )
    return findings


def _require_preload(
    rule: Rule, sources: list[Source], class_paths: dict[str, str]
) -> list[Finding]:
    if not class_paths:
        return []
    names = sorted(class_paths, key=lambda name: (-len(name), name))
    reference_re = re.compile(
        r"\b(" + "|".join(re.escape(name) for name in names) + r")\s*\."
    )
    findings: list[Finding] = []
    for source in sources:
        preloaded = set(PRELOAD_RE.findall("\n".join(source.strings)))
        for number, line in enumerate(source.code, 1):
            for match in reference_re.finditer(line):
                declaring = class_paths[match.group(1)]
                if declaring == source.relative:
                    continue
                if f"res://{declaring}" in preloaded:
                    continue
                findings.append(
                    Finding(
                        relative=source.relative,
                        line=number,
                        rule_id=rule.id,
                        summary=f"{rule.summary} ({match.group(1)})",
                        why=rule.why,
                        instead=rule.instead,
                        code=line.strip(),
                    )
                )
    return findings


def collect_class_paths(sources: list[Source]) -> dict[str, str]:
    """Map every declared `class_name` to the script that declares it.

    Built from the whole scanned tree rather than per zone: a bare reference is
    a problem wherever it appears, regardless of where the class lives.
    """
    class_paths: dict[str, str] = {}
    for source in sources:
        for line in source.code:
            match = CLASS_NAME_RE.search(line)
            if match:
                class_paths[match.group(1)] = source.relative
    return class_paths


def run_rules(manifest: Manifest, sources: list[Source]) -> list[Finding]:
    class_paths = collect_class_paths(sources)
    findings: list[Finding] = []
    for rule in manifest.rules:
        in_scope = [source for source in sources if rule.applies_to(source.relative)]
        if not in_scope:
            continue
        if rule.kind == "require-preload":
            findings.extend(_require_preload(rule, in_scope, class_paths))
        else:
            findings.extend(_forbid(rule, in_scope))
    return findings


def apply_hatches(
    sources: list[Source], findings: list[Finding]
) -> tuple[list[Finding], list[Hatch]]:
    """Drop hatched findings; return what survives plus every hatch, used or not."""
    by_file = {source.relative: source for source in sources}
    surviving: list[Finding] = []
    for finding in findings:
        source = by_file[finding.relative]
        matching = [
            hatch
            for hatch in source.hatches.get(finding.line, [])
            if hatch.rule_id == finding.rule_id
        ]
        if matching:
            for hatch in matching:
                hatch.used = True
            continue
        surviving.append(finding)
    all_hatches = [
        hatch
        for source in sources
        for hatches in source.hatches.values()
        for hatch in hatches
    ]
    return surviving, all_hatches


def stale_hatch_findings(hatches: list[Hatch]) -> list[Finding]:
    return [
        Finding(
            relative=hatch.relative,
            line=hatch.line,
            rule_id="stale-arch-allow",
            summary=f"hatch for `{hatch.rule_id}` suppresses nothing",
            why=(
                "the line no longer violates that rule, so the hatch is dead weight "
                "that makes the allow budget lie about how much is suppressed"
            ),
            instead="delete the hatch comment and lower `allow_budget` in the manifest",
            code="",
        )
        for hatch in hatches
        if not hatch.used
    ]


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def check(root: Path, rules_path: Path, allow_budget: int | None) -> int:
    manifest = load_manifest(rules_path)
    budget = manifest.settings.allow_budget if allow_budget is None else allow_budget

    known_rules = {rule.id for rule in manifest.rules}
    sources = load_sources(root, known_rules, manifest.settings.min_reason_length)
    if not sources:
        raise ConfigError(
            f"{root}: `{SCAN_GLOB}` matched no files; nothing was checked"
        )

    for name, zone in manifest.zones.items():
        if zone.allow_empty:
            continue
        if not any(zone.matches(source.relative) for source in sources):
            raise ConfigError(
                f"[zones.{name}]: matches no files under {root}. A zone that "
                "matches nothing enforces nothing — fix the globs, or set "
                "`allow_empty = true` if the zone is staged ahead of the code."
            )

    findings, hatches = apply_hatches(sources, run_rules(manifest, sources))
    findings.extend(stale_hatch_findings(hatches))
    findings.sort(key=lambda finding: finding.sort_key)

    for finding in findings:
        print(render(finding), file=sys.stderr)

    used = len(hatches)
    if used > budget:
        print(
            f"arch-allow budget exceeded: {used} hatch(es) present, budget is "
            f"{budget}. Remove a hatch, or raise the budget in the manifest and "
            "say why in the commit message.",
            file=sys.stderr,
        )
        return EXIT_FINDINGS
    if used < budget:
        print(
            f"note: {used} arch-allow hatch(es) present, budget is {budget}; "
            f"ratchet `allow_budget` down to {used}.",
            file=sys.stderr,
        )

    return EXIT_FINDINGS if findings else EXIT_CLEAN


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check OpenEBfD scripts against the architecture manifest.",
    )
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="project root to scan (default: the repository containing this script)",
    )
    parser.add_argument(
        "--rules",
        type=Path,
        default=None,
        help=(
            f"rule manifest (default: {DEFAULT_RULES_PATH} in this script's own "
            "repository, so a scanned root may be a throwaway fixture tree)"
        ),
    )
    parser.add_argument(
        "--allow-budget",
        type=int,
        default=None,
        help="override the manifest's allow_budget (for the checker's own tests)",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    rules_path = args.rules
    if rules_path is None:
        rules_path = Path(__file__).resolve().parent.parent / DEFAULT_RULES_PATH

    try:
        return check(root, rules_path, args.allow_budget)
    except ConfigError as error:
        print(f"check_architecture: {error}", file=sys.stderr)
        return EXIT_BROKEN_CONFIG


if __name__ == "__main__":
    sys.exit(main())
