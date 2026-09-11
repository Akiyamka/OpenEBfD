# Slice pipeline

Three models from two providers working one slice at a time, driven by
[Paseo](https://paseo.sh). One command:

```bash
tools/pipeline/run.sh          # one slice
tools/pipeline/run.sh 3        # three slices in a row
tools/pipeline/run.sh --check  # preflight only, creates nothing
```

## Running it from Paseo instead of a terminal

`paseo.json` registers the driver as workspace scripts, so `slice`,
`slice-x3` and `slice-check` appear in the Paseo UI with start/stop and a
managed terminal behind each:

```bash
paseo script ls
paseo script start slice        # same thing from the CLI
paseo script stop slice
```

Do **not** drive a slice by typing at the architect in the Paseo chat. It is one
agent with no reviewer, no coder, no tree fingerprint and no round limits, and
its own brief forbids it from writing code — so the best case is that it plans
and stops. The chat is for asking the architect things, not for running work.

One operational note: the daemon belongs to whoever started it. Started by the
desktop app, it dies when you quit the app, and a run dies with it. `paseo start`
from a terminal outlives the app.

## The roles

| role | model | mode | lifetime |
| --- | --- | --- | --- |
| **architect** | `claude/claude-sonnet-5` | `bypassPermissions` | permanent — one agent across every slice |
| **reviewer** | `codex/gpt-5.6-sol`, thinking `high` | `full-access` | one per slice |
| **coder** | `codex/gpt-5.6-terra`, thinking `high` | `full-access` | one per slice |

The architect is the only role with memory. The reviewer and the coder are
destroyed when a slice lands and created fresh for the next one, so anything
they need has to be written down rather than remembered — which is why every
handoff is a file.

Override any of it per run: `CODER_PROVIDER=codex/gpt-5.5 tools/pipeline/run.sh`.

### Why none of the modes prompt

Claude's `auto` mode does not silently approve a plain `Write` — it raises a
permission request, and an agent with an unanswered request sits in status
`permission` while `paseo send` has already returned. An unattended pipeline
built on it stalls on its first file.

So the architect runs in `bypassPermissions`. Set `ARCHITECT_MODE=auto` if you
would rather approve its commits by hand.

The reviewer's `full-access` is not a relaxation. Codex has no read-only mode —
its `auto` already permits workspace writes — so a stricter mode would buy
prompts that stall the run, not a reviewer that cannot edit. What keeps the
reviewer off the tree is the fingerprint check around every review step, and
that check is the thing that has to hold.

The driver still handles a permission request if one appears: by default it
stops and hands you the request, because with these modes nothing should be
asking. `AUTO_PERMIT=1` approves them instead.

## The loop

```
architect  STEP=next-slice   → .pipeline/slice.md + slice.json
     ↓
reviewer   STEP=review-plan  → .pipeline/plan-verdict.json
     │        changes_requested → architect STEP=plan-questions → revision+1 → repeat (≤3)
     ↓ approved
coder      STEP=implement    → working tree + .pipeline/coder-report.md
     ↓
reviewer   STEP=review-code  → .pipeline/code-verdict.json
     │        rework → coder STEP=rework → repeat (≤3)
     ↓ approved
architect  STEP=land         → docs, plan.md, slices.md row, one commit
     ↓
reviewer and coder destroyed; architect carries on
```

## Why handoffs are files

`paseo send --json` returns a status envelope — `{agentId, status, message}` —
not the agent's reply. Reading a role's answer out of the chat stream was never
available, so every handoff goes through a file under `.pipeline/`, validated
against `schemas/` before the driver acts on it.

That turned out to be the better design anyway. Every decision in a run is a
file you can read afterwards, the schemas are the same text the agents are told
to satisfy, and a malformed verdict fails at the driver instead of halfway
through the next step.

`.pipeline/` is gitignored. Each slice's artefacts are archived to
`.pipeline/runs/<timestamp>-<slice>-<outcome>/` when it lands or when the run
stops.

## Where it stops for a human

By design, not by failure:

- the architect writes `status: "blocked"` — a decision only you can make;
- the reviewer returns `escalate` on a plan or a diff;
- three plan rounds or three code rounds without agreement;
- **the reviewer touched the working tree** — its one hard rule. The driver
  fingerprints staged content, unstaged content and untracked files around every
  review step, so a reviewer that "just fixes" something aborts the run rather
  than quietly mixing its edits into the coder's diff;
- the architect finished `STEP=land` without producing a commit;
- any agent raised a permission request (unless `AUTO_PERMIT=1`).

In all of those the reviewer and the coder are left **alive**: their context is
the most useful thing in the room when you take over. Find them with
`paseo ls --label pipeline=openebfd`, attach with `paseo attach <id>`, and delete
them yourself when you are done.

## Constraints this repo puts on it

- **No worktrees, no parallelism.** All three roles share the one checkout.
  `tools/godot-container` mounts a single `/workspace`, so two container
  commands at once produce project-path and class-loading errors that read as
  real test failures (`AGENTS.md`, "Godot container"). The pipeline is
  sequential for that reason, not for simplicity.
- **A clean tree to start.** The reviewer forms its verdict from `git diff`;
  anything already dirty would be reviewed as if the coder wrote it.
- **The coder gets no architecture feedback for free.** The `PostToolUse` hook
  in `.claude/settings.json` is wired for Claude Code, and the coder is Codex.
  Its brief tells it to run `python3 tools/check_architecture.py` itself.

## Files

```
tools/pipeline/
  run.sh              the driver — the whole state machine
  validate.mjs        JSON Schema subset validator, no dependencies
  roles/*.md          standing briefs; each agent reads its own on creation
  schemas/*.json      the three handoff contracts
docs/architecture/plan.md   the queue, owned by the architect
```
