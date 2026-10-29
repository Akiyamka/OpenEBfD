#!/usr/bin/env python3
"""Compare repeated AP7 and hybrid cold mound calls without a worktree."""

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
MOUND = "scripts/world/map/spice_mound.gd"
RESULT = re.compile(r"^cold_json:\s*(\{.*\})$", re.MULTILINE)


def run(command, timeout=900):
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                          check=True, timeout=timeout)


def container(overlay, arguments, entrypoint=None):
    cmd = ["podman", "run", "--rm", "--userns=keep-id", "--security-opt",
           "label=disable", "--timeout", "850", "--volume", f"{ROOT}:/workspace:ro"]
    if overlay:
        cmd += ["--volume", f"{overlay}:/workspace/{MOUND}:ro"]
    cmd += ["--workdir", "/workspace"]
    if entrypoint:
        cmd += ["--entrypoint", entrypoint]
    return run(cmd + ["openebfd-godot:4.7"] + arguments)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes", default="16,50,200,1000")
    parser.add_argument("--samples-per-batch", type=int, default=25)
    parser.add_argument("--batches", type=int, default=5)
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",")]
    changed = run(["git", "diff", "--name-only", "--diff-filter=M", "HEAD", "--", MOUND]).stdout.splitlines()
    if changed != [MOUND]:
        raise ValueError("mound is not a modified tracked file")
    head = run(["git", "show", f"HEAD:{MOUND}"]).stdout.encode()
    expected = hashlib.sha256(head).hexdigest()
    with tempfile.TemporaryDirectory(prefix="ap23-cold-") as directory:
        overlay = Path(directory) / "spice_mound.gd"
        overlay.write_bytes(head)
        actual = container(overlay, [f"/workspace/{MOUND}"], "/usr/bin/sha256sum").stdout.split()[0]
        if actual != expected or hashlib.sha256(overlay.read_bytes()).hexdigest() != expected:
            raise ValueError("HEAD overlay SHA mismatch")
        print(f"HEAD mound SHA-256 {expected}; overlay verified; tree mounted read-only", flush=True)
        verdicts = []
        for pair in range(3):
            results = {}
            order = ("HEAD", "tree") if pair % 2 == 0 else ("tree", "HEAD")
            for arm in order:
                process = container(overlay if arm == "HEAD" else None, [
                    "godot", "--headless", "--path", "/workspace", "--script",
                    "res://tests/perf/spice_mound_contact_cost_run.gd", "--",
                    "--cold-only", f"--sizes={args.sizes}",
                    f"--samples-per-batch={args.samples_per_batch}",
                    f"--batches={args.batches}"])
                if "AP23 cold samples: PASS" not in process.stdout or "SCRIPT ERROR" in process.stdout:
                    raise ValueError(f"{arm} workload failed: {process.stdout[-3000:]} {process.stderr[-1000:]}")
                rows = [json.loads(row) for row in RESULT.findall(process.stdout)]
                if len(rows) != len(sizes) * args.batches:
                    raise ValueError(f"{arm} workload rows {len(rows)}")
                for size in sizes:
                    subset = sorted((row for row in rows if row["size"] == size), key=lambda row: row["batch"])
                    if (len(subset) != args.batches or any(len(row["samples_us"]) != args.samples_per_batch
                        or row["contacts"] != [1, 1] or row["bucket_writes_delta"] != 0
                        or row["cell_probes_delta"] != 0 for row in subset)):
                        raise ValueError(f"{arm} workload mismatch at {size}: {subset}")
                    print(f"pair {pair + 1} {arm} size {size}: batches {[row['median_us'] for row in subset]} "
                          f"ranges {[(row['min_us'], row['max_us']) for row in subset]} contacts [1, 1] grid delta 0/0", flush=True)
                results[arm] = rows
            pair_status = {}
            for size in sizes:
                h = sorted((row for row in results["HEAD"] if row["size"] == size), key=lambda row: row["batch"])
                t = sorted((row for row in results["tree"] if row["size"] == size), key=lambda row: row["batch"])
                hm = statistics.median(row["median_us"] for row in h)
                tm = statistics.median(row["median_us"] for row in t)
                diffs = [a["median_us"] - b["median_us"] for a, b in zip(t, h)]
                centre = statistics.median(diffs)
                noise = 3 * 1.4826 * statistics.median(abs(value - centre) for value in diffs)
                tolerance = max(5.0, 0.02 * hm, noise)
                status = "INCONCLUSIVE" if noise > 0.1 * hm else "PASS" if tm - hm <= tolerance else "FAIL"
                pair_status[size] = status
                print(f"pair {pair + 1} size {size}: HEAD {hm:.3f} tree {tm:.3f} delta {tm-hm:.3f} "
                      f"paired_noise {noise:.3f} tolerance {tolerance:.3f} us {status}", flush=True)
            verdicts.append(pair_status)
        quiet_pass = sum(all(value == "PASS" for value in pair.values()) for pair in verdicts)
        quiet_fail = any(sum(pair[size] == "FAIL" for pair in verdicts) >= 2 for size in sizes)
        if quiet_fail:
            print("AP23 cold HEAD/tree: FAIL")
            return 1
        if quiet_pass >= 2 and not any("FAIL" in pair.values() for pair in verdicts):
            print("AP23 cold HEAD/tree: PASS")
            return 0
        print("AP23 cold HEAD/tree: INCONCLUSIVE")
        return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"AP23 cold HEAD/tree: ERROR {error}", file=sys.stderr)
        sys.exit(2)
