#!/usr/bin/env python3
"""Alternate HEAD and tree AO1 warm calls and snapshot-key checks."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
COMBAT = "scripts/combat/combat_line_of_fire.gd"
MOUND = "scripts/world/map/spice_mound.gd"
ROW = re.compile(r"^combat_cost_json: (\{.*\})$", re.MULTILINE)


def run(command, timeout=300):
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                          check=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix="ap23-combat-") as directory:
        overlays = {}
        for path in (COMBAT, MOUND):
            source = run(["git", "show", f"HEAD:{path}"]).stdout.encode()
            target = Path(directory) / Path(path).name
            target.write_bytes(source)
            digest = hashlib.sha256(source).hexdigest()
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError(f"HEAD overlay checksum mismatch: {path}")
            overlays[path] = (target, digest)
            print(f"HEAD {path} SHA-256 {digest}; verified", flush=True)
        for pair in range(3):
            results = {}
            order = ("HEAD", "tree") if pair % 2 == 0 else ("tree", "HEAD")
            for arm in order:
                command = ["podman", "run", "--rm", "--userns=keep-id",
                           "--security-opt", "label=disable", "--timeout", "280",
                           "--volume", f"{ROOT}:/workspace:ro"]
                if arm == "HEAD":
                    for path, (target, _) in overlays.items():
                        command += ["--volume", f"{target}:/workspace/{path}:ro"]
                command += ["--workdir", "/workspace", "openebfd-godot:4.7",
                            "godot", "--headless", "--path", "/workspace",
                            "--script", "res://tests/perf/friendly_line_scaling_run.gd",
                            "--", "--combat-cost"]
                process = run(command)
                if "SCRIPT ERROR" in process.stdout or "Parse Error" in process.stdout:
                    raise ValueError(f"{arm} script error: {process.stdout[-3000:]}")
                rows = {row["size"]: row for row in
                        (json.loads(value) for value in ROW.findall(process.stdout))}
                if sorted(rows) != [16, 200]:
                    raise ValueError(f"{arm} missing combat cost rows: {process.stdout[-3000:]}")
                results[arm] = rows
                for size, row in rows.items():
                    print(f"pair {pair + 1} {arm} {size}: key {row['key_us']:.3f} "
                          f"range {row['key_range_us']}; AO1 {row['call_us']:.3f} "
                          f"range {row['call_range_us']}; ids {row['local_ids']}", flush=True)
            for size in (16, 200):
                head, tree = results["HEAD"][size], results["tree"][size]
                if head["local_ids"] != tree["local_ids"]:
                    raise ValueError(f"workload differs at size {size}")
                print(f"pair {pair + 1} {size}: tree minus HEAD key "
                      f"{tree['key_us'] - head['key_us']:+.3f} us/call, AO1 "
                      f"{tree['call_us'] - head['call_us']:+.3f} us/call", flush=True)
        print("combat key diagnostic: complete (three alternating pairs)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"combat key diagnostic: ERROR {error}", file=sys.stderr)
        sys.exit(2)
