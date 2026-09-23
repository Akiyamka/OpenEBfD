#!/usr/bin/env bash
#
# Three-role slice pipeline on top of Paseo.
#
#   architect (claude/sonnet-5)   picks the slice, answers the reviewer, lands it
#   reviewer  (codex/sol)         reviews the plan, then reviews the code
#   coder     (codex/terra, high) implements the slice
#
# The architect is a single long-lived agent. The reviewer and the coder are
# created per slice and destroyed when it lands, which is what "cleared before
# each slice" means here.
#
# Roles never talk to each other. Every handoff is a file under .pipeline/,
# validated against tools/pipeline/schemas/ before it is acted on, and archived
# under .pipeline/runs/ afterwards. That is deliberate: `paseo send --json`
# returns a status envelope, not the agent's reply, so parsing chat was never on
# the table -- and files leave an audit trail that chat would not.
#
# Usage:  tools/pipeline/run.sh [slices]     # default 1
#         SLICE_LIMIT=3 tools/pipeline/run.sh
#         tools/pipeline/run.sh --check       # preflight only, creates nothing
#         tools/pipeline/run.sh --resume      # continue a handed-back slice
#
# Resuming picks the slice back up from whatever .pipeline/ still holds, reusing
# the reviewer and coder the handback deliberately left alive. Write your own
# input to .pipeline/answer.md first if the stop needed a decision from you --
# it reaches the architect (plan phase) or the coder (code phase) as one more
# file handoff, which is what every other role already gets.
#
# Stops and hands the run back to you when: the architect reports `blocked`, the
# reviewer says `escalate`, a round limit is hit, or the reviewer mutates the
# working tree.

set -euo pipefail

# ---------------------------------------------------------------- configuration

ARCHITECT_PROVIDER="${ARCHITECT_PROVIDER:-claude/claude-sonnet-5}"
# bypassPermissions, not auto: Claude's "auto" mode still raises a permission
# request for a plain Write, and a request nobody answers is a stalled run --
# measured, not assumed (a haiku agent asked to write one file sat in status
# `permission` until it was allowed by hand). Switch this to `auto` if you would
# rather babysit the architect than let it commit unattended.
ARCHITECT_MODE="${ARCHITECT_MODE:-bypassPermissions}"

REVIEWER_PROVIDER="${REVIEWER_PROVIDER:-codex/gpt-5.6-sol}"
REVIEWER_THINKING="${REVIEWER_THINKING:-high}"
# Codex has no read-only mode: its `auto` already permits workspace writes, so
# choosing it over full-access would buy prompts that stall the run, not safety.
# What actually keeps the reviewer off the tree is the fingerprint check around
# every review step -- that is the control, so it is the one that has to hold.
REVIEWER_MODE="${REVIEWER_MODE:-full-access}"

CODER_PROVIDER="${CODER_PROVIDER:-codex/gpt-5.6-terra}"
CODER_THINKING="${CODER_THINKING:-high}"
CODER_MODE="${CODER_MODE:-full-access}"

# Answer permission requests automatically instead of stopping. Off by default:
# with the modes above nothing should ask, so a request that does appear means
# something is not as configured, and that is worth a human rather than a
# rubber stamp.
AUTO_PERMIT="${AUTO_PERMIT:-0}"

# Rounds before the run stops for a human. Three is enough for a real
# disagreement and short enough that a loop between two confident models costs
# an evening rather than a week.
MAX_PLAN_ROUNDS="${MAX_PLAN_ROUNDS:-3}"
MAX_CODE_ROUNDS="${MAX_CODE_ROUNDS:-3}"

# Per-step wall clock. `make godot-test` in the container is the slow one.
STEP_TIMEOUT="${STEP_TIMEOUT:-5400}"

# How long to keep watching for a step's output after its agent claims to be
# idle. See wait_for_artifact: idle is a hint, the artifact is the fact. The
# land step gets its own, larger grace because the architect re-runs the suite
# and reads the whole diff before it commits.
STEP_GRACE="${STEP_GRACE:-600}"
LAND_GRACE="${LAND_GRACE:-1800}"

CHECK_ONLY=0
RESUME=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --check)  CHECK_ONLY=1 ;;
    --resume) RESUME=1 ;;
    *) printf 'неизвестный флаг: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
SLICE_LIMIT="${SLICE_LIMIT:-${1:-1}}"
if (( CHECK_ONLY )); then SLICE_LIMIT=0; fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPE="$REPO_ROOT/.pipeline"
ROLES="$REPO_ROOT/tools/pipeline/roles"
SCHEMAS="$REPO_ROOT/tools/pipeline/schemas"
VALIDATE="$REPO_ROOT/tools/pipeline/validate.mjs"
LABEL_NS="pipeline=openebfd"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------- output

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; BLUE=$'\033[34m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; OFF=""; }

# All progress output goes to stderr on purpose: create_agent returns the agent
# id through stdout, and a stray log line there would be captured as the id.
log()   { printf '%s\n' "${DIM}[$(date +%H:%M:%S)]${OFF} $*" >&2; }
step()  { printf '\n%s\n' "${BOLD}${BLUE}== $* ==${OFF}" >&2; }
ok()    { printf '%s\n' "${GREEN}✓${OFF} $*" >&2; }
warn()  { printf '%s\n' "${YELLOW}!${OFF} $*" >&2; }
die()   { printf '\n%s %s\n' "${RED}✗${OFF}" "$*" >&2; exit 1; }

# Stopping for a human is a normal outcome, not a crash: archive what we have
# and say plainly what is needed.
handback() {
  printf '\n%s\n' "${BOLD}${YELLOW}── передаю тебе ──${OFF}"
  printf '%s\n' "$1"
  if [[ -n "${SLICE_ID:-}" ]]; then archive_run "${SLICE_ID}" "handback"; fi
  printf '%s\n' "${DIM}Артефакты: ${ARCHIVE_DIR:-$PIPE}${OFF}"
  printf '%s\n' "${DIM}Агенты оставлены живыми: paseo ls --label pipeline=openebfd${OFF}"
  printf '\n%s\n' "${BOLD}Как продолжить:${OFF}"
  printf '%s\n' "  1. Если нужно твоё решение — напиши его в ${BOLD}.pipeline/answer.md${OFF}"
  printf '%s\n' "     (обычным текстом; он уйдёт архитектору или кодеру как обычный хендоф)."
  printf '%s\n' "  2. ${BOLD}tools/pipeline/run.sh --resume${OFF}  — или скрипт ${BOLD}slice-resume${OFF} в Paseo."
  printf '%s\n' "${DIM}  Если прогон встал только из-за лимита раундов, ответ не нужен — просто продолжи.${OFF}"
  exit 2
}

# ----------------------------------------------------------------- basic helpers

# One hash over everything a role could have changed: staged and unstaged
# content, plus untracked files. `git status --porcelain` alone is not enough --
# a file that is already modified stays "M" when its content changes again.
tree_fingerprint() {
  {
    git -C "$REPO_ROOT" rev-parse HEAD
    git -C "$REPO_ROOT" status --porcelain
    git -C "$REPO_ROOT" diff
    git -C "$REPO_ROOT" diff --cached
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -z \
      | xargs -0 -r sha256sum 2>/dev/null || true
  } | sha256sum | cut -d' ' -f1
}

paseo_json() { paseo "$@" --json 2>/dev/null; }

# Newest agent id carrying every label given.
find_agent() {
  local args=() label
  for label in "$@"; do args+=(--label "$label"); done
  paseo_json ls -g "${args[@]}" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        const rows = s.trim() ? JSON.parse(s) : [];
        process.stdout.write(rows.length ? rows[0].id : "");
      })'
}

# The workspace every role runs in: the *local* one rooted at this checkout.
# `isolation` is checked rather than assumed -- a Paseo-managed worktree would
# also match on nothing else, and worktrees are exactly what this repo cannot
# use: tools/godot-container mounts one /workspace, and symlinked assets under a
# second checkout hang it.
resolve_workspace() {
  paseo_json workspace ls | node -e 'let s="";
    process.stdin.on("data",d=>s+=d).on("end",()=>{
      const rows = s.trim() ? JSON.parse(s) : [];
      const hit = rows.find(w => w.cwd === process.argv[1] && w.isolation === "local");
      process.stdout.write(hit ? hit.workspaceId : "");
    })' "$REPO_ROOT"
}

# ------------------------------------------------------------- agent lifecycle

# Create an agent whose first turn is just reading its standing brief. Cheap,
# and it fails here rather than three steps into a slice if a provider is
# misconfigured.
create_agent() {
  local role="$1" provider="$2" mode="$3" thinking="$4"; shift 4
  local extra_labels=("$@") args=()

  args=(run --provider "$provider" --mode "$mode" --cwd "$REPO_ROOT"
        --title "pipeline-$role" --label "$LABEL_NS" --label "role=$role")
  if [[ -n "$thinking" ]]; then args+=(--thinking "$thinking"); fi
  local label; for label in "${extra_labels[@]}"; do args+=(--label "$label"); done
  if [[ -n "${PIPELINE_WORKSPACE:-}" ]]; then args+=(--workspace "$PIPELINE_WORKSPACE"); fi

  log "создаю ${BOLD}$role${OFF} ($provider${thinking:+, thinking=$thinking}, mode=$mode)"
  timeout "$STEP_TIMEOUT" paseo "${args[@]}" \
    "Read tools/pipeline/roles/${role}.md. That is your standing brief for this
whole session — follow it for every message that follows. Read AGENTS.md too.
Do not start any work now: reply with one line naming your role and the step
names you accept, and wait." >/dev/null \
    || die "не удалось создать агента $role"

  # No await_settled here on purpose: this function's value is read through a
  # command substitution, and exiting a subshell -- which is all `handback` or
  # `die` can do in here -- would be captured as the agent id rather than
  # stopping the run. The caller settles the agent it just got back.
  find_agent "$LABEL_NS" "role=$role" "${extra_labels[@]}"
}

agent_status() {
  paseo_json inspect "$1" | node -e 'let s="";
    process.stdin.on("data",d=>s+=d).on("end",()=>{
      try { const j=JSON.parse(s); process.stdout.write(j.Status||j.status||""); }
      catch { process.stdout.write(""); }
    })'
}

# `paseo send` returns as soon as the agent stops moving -- which includes
# stopping to ask for a permission it will never be granted, not just finishing.
# So settling is checked here rather than inferred from send returning.
await_settled() {
  local agent="$1" description="$2" deadline=$(( SECONDS + STEP_TIMEOUT ))
  local status unknown=0
  while (( SECONDS < deadline )); do
    status="$(agent_status "$agent")"
    case "$status" in
      idle)
        return 0 ;;
      error|failed|crashed)
        die "агент упал на шаге: $description — paseo logs ${agent:0:8} --filter errors" ;;
      "")
        # An empty status is a daemon hiccup or a vanished agent. Retrying twice
        # tells those apart without treating "cannot tell" as "finished", which
        # would surface later as a confusing missing-handoff error.
        unknown=$(( unknown + 1 ))
        if (( unknown >= 3 )); then
          die "не читается статус агента на шаге: $description (агент удалён? демон упал?)"
        fi ;;
      permission)
        if (( AUTO_PERMIT )); then
          log "автоодобряю запрос разрешения на шаге: $description"
          paseo permit allow "$agent" >/dev/null 2>&1 || true
        else
          handback "Агент ждёт разрешения на шаге: $description

$(paseo permit ls 2>/dev/null)

Разреши вручную (paseo permit allow <agent>) и запусти прогон снова,
либо запусти с AUTO_PERMIT=1, если это должно проходить само."
        fi ;;
      *)
        unknown=0 ;;
    esac
    # Blocks until idle or 30s, whichever comes first: responsive when the agent
    # finishes, and a bounded pause when it has not, without a spin loop.
    paseo wait "$agent" --timeout 30 >/dev/null 2>&1 || true
  done
  die "агент не завершил шаг за ${STEP_TIMEOUT}s: $description (статус $status)"
}

# An agent reporting `idle` is not proof that its step finished. On slice F1 the
# daemon called the architect idle during STEP=land; the driver checked HEAD,
# saw no new commit and died -- and the commit appeared eleven minutes later,
# from an agent that had never actually stopped. Every step produces something
# observable, so wait for that rather than trusting the status that lied.
wait_for_artifact() {
  local description="$1" timeout_s="$2"; shift 2
  if "$@"; then return 0; fi
  local deadline=$(( SECONDS + timeout_s ))
  log "результата шага «$description» ещё нет — жду до ${timeout_s}s"
  while (( SECONDS < deadline )); do
    sleep 15
    if "$@"; then
      ok "результат появился: агент работал дольше, чем о себе сообщал"
      return 0
    fi
  done
  return 1
}

head_moved() { [[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" != "$1" ]]; }

coder_left_work() {
  [[ -f "$PIPE/coder-report.md" ]] && [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]
}

send_step() {
  local agent="$1" description="$2" prompt="$3"
  log "→ $description"
  timeout "$STEP_TIMEOUT" paseo send "$agent" --prompt "$prompt" >/dev/null 2>&1 \
    || die "не удалось отправить шаг: $description"
  await_settled "$agent" "$description"
}

delete_agent() { [[ -n "${1:-}" ]] && paseo delete "$1" >/dev/null 2>&1 || true; }

# ------------------------------------------------------------ handoff validation

# Validate a handoff file, and give the agent exactly one chance to fix its own
# output before the run dies. Anything worse than a malformed field is a real
# problem and should stop, not be retried into existence.
expect_json() {
  local agent="$1" file="$2" schema="$3" description="$4"
  local path="$PIPE/$file" errors

  if ! wait_for_artifact "$file" "$STEP_GRACE" test -f "$path"; then
    send_step "$agent" "напоминание: файл $file не создан" \
"You did not write .pipeline/$file. Write it now, matching
tools/pipeline/schemas/$(basename "$schema"). Write nothing else."
    [[ -f "$path" ]] || die "$description: агент так и не создал $file"
  fi

  local rc=0
  errors="$(node "$VALIDATE" "$schema" "$path" 2>&1)" || rc=$?
  if (( rc == 2 )); then die "валидатор сломан на $file: $errors"; fi
  if (( rc != 0 )); then
    warn "$file не прошёл схему, даю один шанс исправить:"
    printf '%s\n' "${DIM}${errors}${OFF}" >&2
    send_step "$agent" "исправление $file" \
"Your .pipeline/$file does not validate against
tools/pipeline/schemas/$(basename "$schema"):

$errors

Rewrite the file so it validates. Change nothing else, and do not restate it in
chat."
    errors="$(node "$VALIDATE" "$schema" "$path" 2>&1)" \
      || die "$description: $file всё ещё невалиден:
$errors"
  fi
  ok "$file принят"
}

json_field() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const v = JSON.parse(s)[process.argv[1]];
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  })' "$2" < "$1"
}

json_pretty() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    console.log(JSON.stringify(JSON.parse(s), null, 2));
  })' < "$1"; }

# --------------------------------------------------------------------- archive

archive_run() {
  local slice_id="$1" outcome="$2"
  ARCHIVE_DIR="$PIPE/runs/${RUN_ID}-${slice_id}-${outcome}"
  mkdir -p "$ARCHIVE_DIR"
  local f
  for f in slice.md slice.json plan-verdict.json code-verdict.json coder-report.md; do
    if [[ -f "$PIPE/$f" ]]; then cp "$PIPE/$f" "$ARCHIVE_DIR/"; fi
  done
  git -C "$REPO_ROOT" log -1 --stat > "$ARCHIVE_DIR/landed-commit.txt" 2>/dev/null || true
}

clear_handoffs() {
  rm -f "$PIPE"/slice.md "$PIPE"/slice.json "$PIPE"/plan-verdict.json \
        "$PIPE"/code-verdict.json "$PIPE"/coder-report.md
}

# -------------------------------------------------------------------- preflight

preflight() {
  step "preflight"

  command -v paseo >/dev/null || die "paseo не установлен"
  command -v node  >/dev/null || die "node не найден"
  paseo status 2>/dev/null | grep -q "Local Daemon *running" \
    || die "демон Paseo не запущен — подними его: paseo start"

  local providers; providers="$(paseo provider ls 2>/dev/null)"
  local p
  for p in claude codex; do
    grep -qE "^$p .*available" <<<"$providers" || die "провайдер $p недоступен"
  done

  # The reviewer forms its verdict from `git diff`. Anything already dirty here
  # would show up as this slice's work and be reviewed as if the coder wrote it.
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    if (( RESUME )); then
      # A handed-back slice leaves real work behind -- the architect's queue row,
      # and the coder's diff when the stop came during code review. Demanding a
      # clean tree here would mean the only way to resume is to destroy what we
      # are resuming. The reviewer's fingerprint check still runs every round,
      # which is the protection that actually matters.
      log "возобновление: дерево не пустое, это ожидаемо"
    elif (( CHECK_ONLY )); then
      warn "рабочее дерево грязное — настоящий запуск здесь бы остановился"
    else
      die "рабочее дерево грязное — закоммить или отложи изменения перед запуском"
    fi
  fi

  local f
  for f in "$VALIDATE" "$ROLES/architect.md" "$ROLES/reviewer.md" "$ROLES/coder.md" \
           "$SCHEMAS/slice.json" "$SCHEMAS/plan-verdict.json" "$SCHEMAS/code-verdict.json"; do
    [[ -f "$f" ]] || die "нет файла связки: ${f#$REPO_ROOT/}"
  done

  # A model id that has quietly disappeared from a provider is worth catching
  # here rather than three steps into a slice.
  local want
  for want in "$ARCHITECT_PROVIDER" "$REVIEWER_PROVIDER" "$CODER_PROVIDER"; do
    local provider="${want%%/*}" model="${want#*/}"
    paseo provider models "$provider" 2>/dev/null | grep -q "^$model " \
      || die "модель $model недоступна у провайдера $provider"
  done

  mkdir -p "$PIPE/runs"
  ok "демон, провайдеры, модели, файлы связки и дерево в порядке"
}

# ------------------------------------------------------------------- the slice
#
# Every prompt below is a double-quoted string, so a backtick inside one is
# command substitution rather than markdown formatting. Name fields in plain
# words here; the markdown belongs in roles/*.md, which nothing expands.

# Everything a resumed slice needs is already on disk; this only works out which
# phase it stopped in. The coder's report is the marker: it exists only once the
# coder has run, so its presence means the stop happened at or after code review.
resume_phase() {
  # An approved code verdict means the only step left is landing -- re-running
  # the review would spend a round re-approving work that is already approved,
  # and risk a second opinion looping on a diff nobody is going to change.
  if [[ -f "$PIPE/code-verdict.json" ]] \
     && [[ "$(json_field "$PIPE/code-verdict.json" verdict)" == "approved" ]]; then
    printf 'land'
  elif [[ -f "$PIPE/coder-report.md" ]]; then
    printf 'code'
  else
    printf 'plan'
  fi
}

# Hand the human's answer to whichever role is about to act on it. Optional: a
# run that stopped only because it ran out of rounds often needs no answer at
# all, just more rounds.
deliver_answer() {
  local phase="$1"
  if [[ ! -f "$PIPE/answer.md" ]]; then
    log "ответа от человека нет (.pipeline/answer.md) — продолжаю с тем, что есть"
    return 0
  fi
  if [[ "$phase" == "plan" ]]; then
    send_step "$ARCHITECT" "STEP=human-answer" \
"STEP=human-answer

The run stopped and the human answered. Their answer is .pipeline/answer.md.

Fold it into .pipeline/slice.md the way you fold in a reviewer's questions --
by making the brief say what it failed to say, not by appending a note. Then
bump the revision field in .pipeline/slice.json, and set its status back to
\"ready\" if the answer unblocks the slice. Write no code."
    expect_json "$ARCHITECT" slice.json "$SCHEMAS/slice.json" "ответ человека"
    # Without this the run would walk a still-blocked slice into plan review,
    # spending a reviewer round on a brief whose own author says it cannot
    # proceed.
    if [[ "$(json_field "$PIPE/slice.json" status)" == "blocked" ]]; then
      handback "Архитектор считает, что твой ответ слайс не разблокировал:

$(json_pretty "$PIPE/slice.json")"
    fi
  elif [[ "$phase" == "code" ]]; then
    send_step "$CODER" "STEP=human-answer" \
"STEP=human-answer

The run stopped and the human answered. Their answer is .pipeline/answer.md.

Act on it, then update .pipeline/coder-report.md with what you changed. Do not
commit."
  else
    # Land phase: the coder is gone and the code is approved, so the only role
    # left to hear this is the architect, and the only thing left to change is
    # how the slice is landed.
    send_step "$ARCHITECT" "STEP=human-answer" \
"STEP=human-answer

The run stopped before the slice landed and the human answered. Their answer is
.pipeline/answer.md. The code is already approved and is not to be changed.

Take it into account in how you land the slice -- the docs you update, the
commit message -- and say in one line what you did with it."
  fi
  mv -f "$PIPE/answer.md" "$PIPE/answer.used.md"
}

run_slice() {
  local slice_number="$1"
  local phase="plan"

  if (( RESUME )); then
    # Only the first slice of an invocation resumes; any after it start normally.
    RESUME=0
    [[ -f "$PIPE/slice.json" ]] || die "нечего возобновлять: нет .pipeline/slice.json"
    [[ -f "$PIPE/slice.md" ]]   || die "нечего возобновлять: нет .pipeline/slice.md"
    SLICE_ID="$(json_field "$PIPE/slice.json" id)"
    phase="$(resume_phase)"
    step "возобновление слайса $SLICE_ID · фаза: $phase · ревизия $(json_field "$PIPE/slice.json" revision)"

    if [[ "$phase" == "land" ]]; then
      ok "код уже одобрен — остаётся только посадка, ревьювер и кодер не нужны"
    else
    REVIEWER="$(find_agent "$LABEL_NS" "role=reviewer" "slice=$SLICE_ID")"
    if [[ -n "$REVIEWER" ]]; then
      ok "ревьювер ${DIM}${REVIEWER:0:8}${OFF} жив — его контекст по этому слайсу сохранён"
    else
      REVIEWER="$(create_agent reviewer "$REVIEWER_PROVIDER" "$REVIEWER_MODE" \
                  "$REVIEWER_THINKING" "slice=$SLICE_ID" "run=$RUN_ID")"
      [[ -n "$REVIEWER" ]] || die "не удалось поднять ревьювера для возобновления"
      warn "прежний ревьювер не найден, создан новый — он перечитает слайс с нуля"
    fi
    await_settled "$REVIEWER" "ревьювер на возобновлении"

    if [[ "$phase" == "code" ]]; then
      CODER="$(find_agent "$LABEL_NS" "role=coder" "slice=$SLICE_ID")"
      if [[ -n "$CODER" ]]; then
        ok "кодер ${DIM}${CODER:0:8}${OFF} жив"
        await_settled "$CODER" "кодер на возобновлении"
      else
        warn "прежний кодер не найден — поднимаю нового поверх уже написанного диффа"
        CODER="$(create_agent coder "$CODER_PROVIDER" "$CODER_MODE" \
                 "$CODER_THINKING" "slice=$SLICE_ID" "run=$RUN_ID")"
        [[ -n "$CODER" ]] || die "не удалось поднять кодера для возобновления"
        await_settled "$CODER" "создание кодера на возобновлении"
        send_step "$CODER" "STEP=adopt" \
"STEP=adopt

You are taking over a slice that is already implemented. The previous coder is
gone; its work is not. Read .pipeline/slice.md for what was specified,
.pipeline/coder-report.md for what your predecessor says it did, and `git diff`
plus `git status` for what is actually in the tree — the diff is the evidence,
the report is a claim.

Change nothing yet. Reply with one line saying whether the diff and the report
agree, and name any place they do not. The reviewer reviews next."
      fi
    fi
    fi

    deliver_answer "$phase"
  else
    SLICE_ID=""
    clear_handoffs
  fi

  if [[ "$phase" == "plan" ]] && [[ -z "$SLICE_ID" ]]; then
  # ---- 1. architect hands out a slice ------------------------------------
  step "слайс $slice_number · архитектор выбирает работу"
  send_step "$ARCHITECT" "STEP=next-slice" \
"STEP=next-slice

Follow the STEP=next-slice section of tools/pipeline/roles/architect.md.

Write .pipeline/slice.md and .pipeline/slice.json. Nothing else — no code, no
commit. When both files are written, stop."

  expect_json "$ARCHITECT" slice.json "$SCHEMAS/slice.json" "выдача слайса"

  local status; status="$(json_field "$PIPE/slice.json" status)"
  SLICE_ID="$(json_field "$PIPE/slice.json" id)"

  case "$status" in
    done)
      ok "очередь в docs/architecture/plan.md пуста — работы нет"
      return 1 ;;
    blocked)
      handback "Архитектор не может выбрать слайс без твоего решения:

$(json_pretty "$PIPE/slice.json")" ;;
  esac

  [[ -f "$PIPE/slice.md" ]] || die "архитектор не написал .pipeline/slice.md"
  # .pipeline/ is gitignored, so the queue row is the only trace of an in-flight
  # slice that a second reader can see. Without this gate it was written at
  # landing instead -- the file said "empty" for the whole run.
  grep -q "$SLICE_ID" "$REPO_ROOT/docs/architecture/plan.md" \
    || die "слайс $SLICE_ID не заведён в очередь docs/architecture/plan.md — на время прогона очередь врала бы"
  ok "слайс ${BOLD}${SLICE_ID}${OFF}: $(json_field "$PIPE/slice.json" title)"

  # ---- 2. reviewer reviews the plan --------------------------------------
  REVIEWER="$(create_agent reviewer "$REVIEWER_PROVIDER" "$REVIEWER_MODE" \
              "$REVIEWER_THINKING" "slice=$SLICE_ID" "run=$RUN_ID")"
  [[ -n "$REVIEWER" ]] || die "не нашёл созданного ревьювера по меткам"
  await_settled "$REVIEWER" "создание ревьювера"
  fi

  local round approved=0
  if [[ "$phase" != "plan" ]]; then approved=1; fi
  for (( round = 1; approved == 0 && round <= MAX_PLAN_ROUNDS; round++ )); do
    step "слайс $SLICE_ID · ревью плана, раунд $round/$MAX_PLAN_ROUNDS"

    local before; before="$(tree_fingerprint)"
    rm -f "$PIPE/plan-verdict.json"
    send_step "$REVIEWER" "STEP=review-plan" \
"STEP=review-plan

Follow the STEP=review-plan section of tools/pipeline/roles/reviewer.md.
The slice is .pipeline/slice.md (revision $(json_field "$PIPE/slice.json" revision)).

Write .pipeline/plan-verdict.json. Change nothing else in the tree."
    [[ "$(tree_fingerprint)" == "$before" ]] \
      || die "ревьювер изменил рабочее дерево во время ревью плана — это его единственное жёсткое правило, разбирайся вручную"

    expect_json "$REVIEWER" plan-verdict.json "$SCHEMAS/plan-verdict.json" "ревью плана"

    local verdict revision slice_revision
    verdict="$(json_field "$PIPE/plan-verdict.json" verdict)"
    revision="$(json_field "$PIPE/plan-verdict.json" revision)"
    slice_revision="$(json_field "$PIPE/slice.json" revision)"
    [[ "$revision" == "$slice_revision" ]] \
      || die "вердикт вынесен по ревизии $revision, а слайс уже $slice_revision"

    case "$verdict" in
      approved)
        ok "план одобрен"; approved=1; break ;;
      escalate)
        handback "Ревьювер эскалировал план слайса $SLICE_ID:

$(json_pretty "$PIPE/plan-verdict.json")" ;;
      changes_requested)
        warn "ревьювер вернул вопросы в архитектуру"
        send_step "$ARCHITECT" "STEP=plan-questions" \
"STEP=plan-questions

Follow the STEP=plan-questions section of tools/pipeline/roles/architect.md.
The reviewer's questions are in .pipeline/plan-verdict.json.

Answer them by rewriting .pipeline/slice.md, then bump the revision field in
.pipeline/slice.json. Write no code."
        expect_json "$ARCHITECT" slice.json "$SCHEMAS/slice.json" "правка слайса"
        if [[ "$(json_field "$PIPE/slice.json" status)" == "blocked" ]]; then
          handback "Архитектор не смог ответить ревьюверу без тебя:

$(json_pretty "$PIPE/slice.json")"
        fi
        [[ "$(json_field "$PIPE/slice.json" revision)" != "$slice_revision" ]] \
          || die "архитектор не поднял revision — следующий раунд был бы холостым" ;;
    esac
  done
  (( approved )) || handback "План слайса $SLICE_ID не сошёлся за $MAX_PLAN_ROUNDS раунда.
Последние вопросы:

$(json_pretty "$PIPE/plan-verdict.json")"

  # ---- 3. coder implements ------------------------------------------------
  if [[ "$phase" == "plan" ]]; then
  step "слайс $SLICE_ID · реализация"
  CODER="$(create_agent coder "$CODER_PROVIDER" "$CODER_MODE" \
           "$CODER_THINKING" "slice=$SLICE_ID" "run=$RUN_ID")"
  [[ -n "$CODER" ]] || die "не нашёл созданного кодера по меткам"
  await_settled "$CODER" "создание кодера"

  send_step "$CODER" "STEP=implement" \
"STEP=implement

Follow tools/pipeline/roles/coder.md. The approved slice is .pipeline/slice.md.

Implement it, run the checks the brief requires, and write
.pipeline/coder-report.md. Do not commit."

  wait_for_artifact "работа кодера" "$STEP_GRACE" coder_left_work \
    || die "кодер не оставил ни отчёта, ни изменений в дереве — ревьюить нечего"
  ok "кодер отработал"
  fi

  # ---- 4. reviewer reviews the code --------------------------------------
  approved=0
  if [[ "$phase" == "land" ]]; then approved=1; fi
  for (( round = 1; approved == 0 && round <= MAX_CODE_ROUNDS; round++ )); do
    step "слайс $SLICE_ID · ревью кода, раунд $round/$MAX_CODE_ROUNDS"

    local before; before="$(tree_fingerprint)"
    rm -f "$PIPE/code-verdict.json"
    send_step "$REVIEWER" "STEP=review-code" \
"STEP=review-code

Follow the STEP=review-code section of tools/pipeline/roles/reviewer.md.
The coder's account is .pipeline/coder-report.md; form your own view from the
diff. Run the checks yourself and record real exit codes.

Write .pipeline/code-verdict.json. Change nothing else in the tree."
    [[ "$(tree_fingerprint)" == "$before" ]] \
      || die "ревьювер изменил дерево во время ревью кода — правки ревьювера смешались бы с работой кодера, разбирайся вручную"

    expect_json "$REVIEWER" code-verdict.json "$SCHEMAS/code-verdict.json" "ревью кода"

    local verdict checks
    verdict="$(json_field "$PIPE/code-verdict.json" verdict)"
    checks="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        process.stdout.write(String((JSON.parse(s).checks_run||[]).length));
      })' < "$PIPE/code-verdict.json")"

    case "$verdict" in
      approved)
        (( checks > 0 )) || die "ревьювер одобрил код с пустым checks_run — одобрение без единой запущенной проверки не считается"
        # A red check is not automatically this slice's fault, and not automatically
        # a fault at all: `make lint` fails in this repo over two oversized files
        # nobody has split yet, and a smoke test that probes a failure path is
        # *supposed* to exit non-zero. A gate that blocked on any red would block
        # every slice forever. What it can demand is that each failure be accounted
        # for rather than passed by in silence.
        local unaccounted
        unaccounted="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            const bad = (JSON.parse(s).checks_run||[]).filter(
              c => c.exit_code !== 0 && !(c.expected === true && c.summary));
            process.stdout.write(bad.map(c => "  exit " + c.exit_code + "  " + c.command).join("\n"));
          })' < "$PIPE/code-verdict.json")"
        [[ -z "$unaccounted" ]] || die "ревьювер одобрил код, не объяснив провалившиеся проверки:
$unaccounted
Каждая ненулевая проверка должна нести summary и, если такой код возврата нормален (падало и до слайса, или это негативный сценарий), expected: true."
        ok "код одобрен ($checks проверк(и) запущено)"; approved=1; break ;;
      escalate)
        handback "Ревьювер эскалировал код слайса $SLICE_ID:

$(json_pretty "$PIPE/code-verdict.json")" ;;
      rework)
        warn "ревьювер вернул код на доработку"
        send_step "$CODER" "STEP=rework" \
"STEP=rework

Follow the STEP=rework section of tools/pipeline/roles/coder.md.
The findings are in .pipeline/code-verdict.json.

Address every blocker and major finding, or push back in the report with your
reasoning. Update .pipeline/coder-report.md with a 'Rework round $round'
section. Do not commit." ;;
    esac
  done
  (( approved )) || handback "Код слайса $SLICE_ID не прошёл ревью за $MAX_CODE_ROUNDS раунда.
Последние замечания:

$(json_pretty "$PIPE/code-verdict.json")"

  # ---- 5. architect lands it ---------------------------------------------
  step "слайс $SLICE_ID · документация и коммит"
  local head_before; head_before="$(git -C "$REPO_ROOT" rev-parse HEAD)"

  send_step "$ARCHITECT" "STEP=land" \
"STEP=land

Follow the STEP=land section of tools/pipeline/roles/architect.md.
The approved verdict is .pipeline/code-verdict.json.

Check the diff yourself, update the docs and docs/architecture/plan.md, add the
slices.md row if any code cites slice $SLICE_ID, run make lint, and commit
everything as one commit with the trailer 'Slice: $SLICE_ID'."

  wait_for_artifact "коммит слайса" "$LAND_GRACE" head_moved "$head_before" \
    || die "архитектор не создал коммит за ${LAND_GRACE}s после шага land — работа осталась в дереве, ничего не потеряно"
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] \
    || warn "после коммита в дереве осталось незакоммиченное:
$(git -C "$REPO_ROOT" status --short)"

  git -C "$REPO_ROOT" log -1 --format='%h %s' | sed "s/^/  ${GREEN}●${OFF} /"
  git -C "$REPO_ROOT" log -1 --format='%b' | grep -q "^Slice: $SLICE_ID$" \
    || warn "в коммите нет трейлера 'Slice: $SLICE_ID' — слайс-индекс это не увидит"

  # ---- 6. clear everyone but the architect --------------------------------
  archive_run "$SLICE_ID" "landed"
  # Clear the handoffs here, not at the next slice's start. Left in place they
  # describe a slice that is already committed, and --resume reads the same
  # files to decide what to continue: it would have re-entered code review on
  # finished work. The archive above is what keeps them.
  clear_handoffs
  delete_agent "$REVIEWER"; delete_agent "$CODER"
  REVIEWER=""; CODER=""
  ok "ревьювер и кодер очищены; архитектор живёт дальше"
  return 0
}

# ------------------------------------------------------------------------ main

REVIEWER=""; CODER=""; SLICE_ID=""; ARCHIVE_DIR=""
# Agents are cleared where the slice lands, not here. This trap only reports,
# because every exit that reaches it is an exit we did not plan for -- a signal,
# a lost daemon, a die() -- and those are exactly the cases where the reviewer's
# and coder's context is worth more than the tidiness of removing them.
cleanup() {
  if [[ -n "${REVIEWER:-}${CODER:-}" ]]; then
    printf '\n%s\n' "${DIM}Агенты слайса оставлены живыми: paseo ls --label pipeline=openebfd${OFF}" >&2
    printf '%s\n' "${DIM}Продолжить: tools/pipeline/run.sh --resume${OFF}" >&2
  fi
}
trap cleanup EXIT

preflight

if (( CHECK_ONLY )); then
  printf '\n%s\n' "${BOLD}роли${OFF}"
  printf '  %-10s %s\n' architect "$ARCHITECT_PROVIDER (mode=$ARCHITECT_MODE)" \
                         reviewer  "$REVIEWER_PROVIDER (thinking=$REVIEWER_THINKING, mode=$REVIEWER_MODE)" \
                         coder     "$CODER_PROVIDER (thinking=$CODER_THINKING, mode=$CODER_MODE)"
  existing="$(find_agent "$LABEL_NS" "role=architect")"
  printf '  %-10s %s\n' архитектор \
    "${existing:-нет — будет создан при первом запуске}"
  printf '\n%s\n' "${BOLD}${GREEN}проверка пройдена${OFF} — связка готова к запуску"
  exit 0
fi

PIPELINE_WORKSPACE="$(resolve_workspace)"

step "архитектор"
ARCHITECT="$(find_agent "$LABEL_NS" "role=architect")"
if [[ -n "$ARCHITECT" ]]; then
  ok "переиспользую живого архитектора ${DIM}${ARCHITECT:0:8}${OFF} — его контекст и есть память проекта"
else
  ARCHITECT="$(create_agent architect "$ARCHITECT_PROVIDER" "$ARCHITECT_MODE" "")"
  [[ -n "$ARCHITECT" ]] || die "не нашёл созданного архитектора по меткам"
  await_settled "$ARCHITECT" "создание архитектора"
  ok "архитектор создан ${DIM}${ARCHITECT:0:8}${OFF}"
fi
# Re-resolve after creation: the very first run has no workspace until paseo
# makes one, and every agent after that must join it rather than start another.
PIPELINE_WORKSPACE="$(resolve_workspace)"
if [[ -n "$PIPELINE_WORKSPACE" ]]; then
  ok "воркспейс ${DIM}${PIPELINE_WORKSPACE}${OFF} (local, $REPO_ROOT)"
else
  warn "воркспейс не определился — роли создадут свои, работать будут в том же дереве"
fi

landed=0
for (( n = 1; n <= SLICE_LIMIT; n++ )); do
  run_slice "$n" || break
  landed=$(( landed + 1 ))
done

printf '\n%s\n' "${BOLD}${GREEN}готово${OFF}: слайсов приземлено — $landed"
if (( landed > 0 )); then git -C "$REPO_ROOT" log --oneline -n "$landed" | sed 's/^/  /'; fi
exit 0
