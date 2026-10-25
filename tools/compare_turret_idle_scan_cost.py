#!/usr/bin/env python3
"""Compare one bound turret's idle_scan call against HEAD runtime overlays."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = [
    "scripts/combat/combat_turret.gd",
    "scripts/match/match_lookup.gd",
    "scripts/units/unit_combat.gd",
    "scripts/buildings/building.gd",
]


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=300)
    if result.returncode:
        raise ValueError(f"command exited {result.returncode}: {command}\n{result.stdout}\n{result.stderr}")
    return result


def podman(overlays, command, entrypoint=None):
    argv = ["podman", "run", "--rm", "--userns=keep-id", "--security-opt", "label=disable",
            "--timeout", "240", "--volume", f"{ROOT}:/workspace:ro"]
    for source, target in overlays:
        argv += ["--volume", f"{source}:/workspace/{target}:ro"]
    argv += ["--workdir", "/workspace"]
    if entrypoint:
        argv += ["--entrypoint", entrypoint]
    return run(argv + ["openebfd-godot:4.7"] + command)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calls", type=int, default=10000)
    args = parser.parse_args()
    if args.calls <= 0:
        parser.error("--calls must be positive")
    with tempfile.TemporaryDirectory(prefix="ap4-head-") as directory:
        overlays = []
        expected = {}
        for name in RUNTIME:
            contents = run(["git", "show", f"HEAD:{name}"]).stdout.encode()
            source = Path(directory) / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(contents)
            overlays.append((source, name))
            expected[name] = hashlib.sha256(contents).hexdigest()
        for name, digest in expected.items():
            observed = podman(overlays, [f"/workspace/{name}"], "/usr/bin/sha256sum").stdout.split()[0]
            if observed != digest:
                raise ValueError(f"HEAD overlay mismatch {name}: {observed} != {digest}")
        for arm, mounted in (("HEAD", overlays), ("tree", [])):
            result = podman(mounted, ["godot", "--headless", "--path", "/workspace", "--script",
                                      "res://tests/perf/turret_idle_scan_cost_run.gd", "--", f"--calls={args.calls}"])
            lines = [line[6:] for line in result.stdout.splitlines() if line.startswith("json: ")]
            if not lines:
                raise ValueError(f"{arm} fixture returned no result: {result.stdout}\n{result.stderr}")
            sample = json.loads(lines[-1])
            if not sample.get("ok") or sample.get("calls") != args.calls:
                raise ValueError(f"{arm} invalid fixture: {sample}")
            for path in ("waiting", "expiry"):
                values = sample[f"{path}_us"]
                if len(values) != 3 or any(value <= 0 for value in values):
                    raise ValueError(f"{arm} invalid {path} samples: {values}")
                print(f"{arm} {path}: {values} us/call; median {statistics.median(values):.3f}; spread {max(values) - min(values):.3f}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(2)
