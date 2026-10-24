#!/usr/bin/env python3
"""Alternating HEAD/tree combat benchmark without a checkout or worktree."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
IMAGE = "openebfd-godot:4.7"
RESULT = re.compile(r"^json:\s*(\{.*\})$", re.MULTILINE)


def command(args, *, check=True, timeout=360):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True,
                          check=check, timeout=timeout)


def podman(overlays, args, entrypoint=None):
    invocation = ["podman", "run", "--rm", "--userns=keep-id",
                  "--security-opt", "label=disable", "--timeout", "300",
                  "--volume", f"{ROOT}:/workspace:ro"]
    for source, target in overlays:
        invocation += ["--volume", f"{source}:/workspace/{target}:ro"]
    invocation += ["--workdir", "/workspace"]
    if entrypoint is not None:
        invocation += ["--entrypoint", entrypoint]
    invocation += [IMAGE]
    return command(invocation + args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ticks", type=int, default=1200)
    parser.add_argument("--warmup-ticks", type=int, default=200)
    args = parser.parse_args()
    paths = command(["git", "diff", "--name-only", "--diff-filter=M",
                     "HEAD", "--", "scripts"]).stdout.splitlines()
    if not paths:
        print("FAIL: no modified tracked runtime file", file=sys.stderr)
        return 2
    changed = False
    head = {}
    with tempfile.TemporaryDirectory(prefix="ap2-head-") as temporary:
        temporary_path = Path(temporary)
        overlays = []
        for name in paths:
            contents = command(["git", "show", f"HEAD:{name}"]).stdout.encode()
            destination = temporary_path / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(contents)
            expected = hashlib.sha256(contents).hexdigest()
            head[name] = expected
            changed |= hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected
            overlays.append((destination, name))
        if not changed:
            print("FAIL: runtime files do not differ from HEAD", file=sys.stderr)
            return 2
        samples = {"HEAD": [], "tree": []}
        for pair in range(3):
            for arm in ("HEAD", "tree"):
                arm_overlays = overlays if arm == "HEAD" else []
                if arm == "HEAD":
                    for name, expected in head.items():
                        digest = podman(arm_overlays, [f"/workspace/{name}"],
                                        entrypoint="/usr/bin/sha256sum")
                        actual = digest.stdout.split()[0] if digest.stdout.split() else ""
                        if actual != expected:
                            print(f"FAIL: overlay byte mismatch for {name}: {actual} != {expected}",
                                  file=sys.stderr)
                            return 2
                label = f"{arm}-{pair + 1}"
                result = podman(arm_overlays, [
                    "godot", "--headless", "--path", "/workspace", "--script",
                    "res://tests/perf/headless_match_perf_run.gd", "--",
                    f"--ticks={args.ticks}", f"--warmup-ticks={args.warmup_ticks}",
                    f"--label={label}",
                ])
                lines = RESULT.findall(result.stdout)
                if not lines:
                    print(result.stdout, result.stderr, file=sys.stderr)
                    print(f"FAIL: no JSON result from {label}", file=sys.stderr)
                    return 2
                sample = json.loads(lines[-1])
                if (not sample.get("ok") or not sample.get("headless")
                        or sample.get("buildings") != 49 or sample.get("units") != 16
                        or sample.get("combat_windows_confirmed") != sample.get("combat_windows_checked")
                        or sample.get("patrol_intervals_confirmed") != sample.get("patrol_intervals_checked")
                        or sample.get("combat_hp_lost", 0) < 600):
                    print(f"FAIL: workload checks for {label}: {sample}", file=sys.stderr)
                    return 2
                rate = float(sample["ticks_per_second"])
                samples[arm].append(rate)
                print(f"{label}: {rate:.3f} ticks/s", flush=True)
        spans = {arm: max(values) - min(values) for arm, values in samples.items()}
        medians = {arm: statistics.median(values) for arm, values in samples.items()}
        tolerance = max(0.3, *spans.values())
        print(f"HEAD median {medians['HEAD']:.3f}, tree median {medians['tree']:.3f}; "
              f"spans HEAD {spans['HEAD']:.3f}, tree {spans['tree']:.3f}; "
              f"tolerance {tolerance:.3f} ticks/s")
        if any(span > 0.6 for span in spans.values()):
            print("INCONCLUSIVE: unstable host")
            return 2
        if medians["tree"] < medians["HEAD"] - tolerance:
            print("FAIL: stable combat-path regression")
            return 1
        print("PASS: stable combat-path throughput")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: command error: {error}", file=sys.stderr)
        sys.exit(2)
