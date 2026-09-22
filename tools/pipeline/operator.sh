#!/usr/bin/env bash
#
# Creates (or finds) the operator agent -- the one agent a human is meant to
# talk to. Everything else in the pipeline is driven by tools/pipeline/run.sh
# and destroyed between slices; the operator is a permanent chat front end that
# starts the driver, reads its output, and turns what you say into the files the
# driver expects.
#
# Usage:  tools/pipeline/operator.sh          # create or reuse, print the id
#         tools/pipeline/operator.sh --new    # replace the existing one
#
# Then open "pipeline-operator" in Paseo and talk to it.

set -euo pipefail

# bypassPermissions because this one is conversational: Claude's `auto` raises a
# permission request even for a plain Write, and an operator that silently sits
# in status `permission` while you wait for it is worse than useless. Its brief
# is what keeps it to one writable file; change the mode in Paseo if you would
# rather approve each step.
OPERATOR_PROVIDER="${OPERATOR_PROVIDER:-claude/claude-sonnet-5}"
OPERATOR_MODE="${OPERATOR_MODE:-bypassPermissions}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
LABEL_NS="pipeline=openebfd"

find_operator() {
  paseo ls -g --label "$LABEL_NS" --label role=operator --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        const rows = s.trim() ? JSON.parse(s) : [];
        process.stdout.write(rows.length ? rows[0].id : "");
      })'
}

existing="$(find_operator)"
if [[ "${1:-}" == "--new" && -n "$existing" ]]; then
  paseo delete "$existing" >/dev/null 2>&1 || true
  existing=""
elif [[ -n "$existing" ]]; then
  printf 'оператор уже есть: %s\nОткрой "pipeline-operator" в Paseo.\n' "$existing"
  exit 0
fi

workspace="$(paseo workspace ls --json 2>/dev/null | node -e 'let s="";
  process.stdin.on("data",d=>s+=d).on("end",()=>{
    const rows = s.trim() ? JSON.parse(s) : [];
    const hit = rows.find(w => w.cwd === process.argv[1] && w.isolation === "local");
    process.stdout.write(hit ? hit.workspaceId : "");
  })' "$REPO_ROOT")"

args=(run --provider "$OPERATOR_PROVIDER" --mode "$OPERATOR_MODE" --cwd "$REPO_ROOT"
      --title pipeline-operator --label "$LABEL_NS" --label role=operator)
if [[ -n "$workspace" ]]; then args+=(--workspace "$workspace"); fi

paseo "${args[@]}" \
"Read tools/pipeline/roles/operator.md — that is your standing brief for this
whole session — and then tools/pipeline/README.md. You are the operator: the
human talks to you in chat and you drive the pipeline for them.

Do not start any work now. Reply with a short greeting that says what you can
run for them and what the pipeline's current state is (read .pipeline/ to find
out whether a slice is mid-flight), then wait." >/dev/null

created="$(find_operator)"
[[ -n "$created" ]] || { printf 'не удалось создать оператора\n' >&2; exit 1; }
printf 'оператор создан: %s\nОткрой "pipeline-operator" в Paseo и пиши ему.\n' "$created"
