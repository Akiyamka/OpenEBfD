#!/usr/bin/env python3
"""Three paired HEAD/tree successful Kobra start timings without a worktree."""

import argparse
import hashlib
import json
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
    parser.add_argument("--calls", type=int, default=2000)
    args = parser.parse_args()
    if args.calls <= 0:
        print("FAIL: calls must be positive", file=sys.stderr)
        return 2
    paths = command(["git", "diff", "--name-only", "--diff-filter=M",
                     "HEAD", "--", "scripts"]).stdout.splitlines()
    if not paths or any(not name.startswith("scripts/") for name in paths):
        print("FAIL: no complete modified tracked runtime set", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="ap5-head-") as temporary:
        base = Path(temporary)
        overlays = []
        digests = {}
        for name in paths:
            contents = subprocess.run(["git", "show", f"HEAD:{name}"], cwd=ROOT,
                                      check=True, capture_output=True).stdout
            source = base / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(contents)
            digests[name] = hashlib.sha256(contents).hexdigest()
            overlays.append((source, name))
        expected_set = set(paths)
        actual_set = {target for _, target in overlays}
        if actual_set != expected_set or len(overlays) != len(paths):
            print(f"FAIL: missing or extra runtime overlay: {expected_set ^ actual_set}",
                  file=sys.stderr)
            return 2
        samples = {"HEAD": [], "tree": []}
        for pair in range(3):
            for arm in ("HEAD", "tree"):
                arm_overlays = overlays if arm == "HEAD" else []
                if arm == "HEAD":
                    for name, expected in digests.items():
                        observed = podman(arm_overlays, [f"/workspace/{name}"],
                                          entrypoint="/usr/bin/sha256sum")
                        digest = observed.stdout.split()[0] if observed.stdout.split() else ""
                        if digest != expected:
                            print(f"FAIL: overlay SHA-256 mismatch for {name}", file=sys.stderr)
                            return 2
                result = podman(arm_overlays, ["godot", "--headless", "--path",
                         "/workspace", "--script",
                         "res://tests/perf/unit_fire_variant_cost_run.gd", "--",
                         f"--calls={args.calls}"])
                found = RESULT.findall(result.stdout)
                if not found:
                    print(result.stdout, result.stderr, file=sys.stderr)
                    print(f"FAIL: no fixture result from {arm}-{pair + 1}", file=sys.stderr)
                    return 2
                sample = json.loads(found[-1])
                if (not sample.get("ok") or sample.get("successes") != args.calls
                        or sample.get("calls") != args.calls):
                    print(f"FAIL: successful-call count from {arm}-{pair + 1}: {sample}",
                          file=sys.stderr)
                    return 2
                value = float(sample["usec_per_success"])
                samples[arm].append(value)
                print(f"{arm}-{pair + 1}: {value:.3f} us/success", flush=True)
        for arm, values in samples.items():
            print(f"{arm} median {statistics.median(values):.3f} us/success; "
                  f"spread {max(values) - min(values):.3f} us/success")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: command error: {error}", file=sys.stderr)
        sys.exit(2)
