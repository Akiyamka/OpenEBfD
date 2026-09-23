#!/usr/bin/env bash
#
# Where the pipeline is, right now, from disk and the daemon -- never from
# anyone's memory of it.
#
# This exists because "re-read the state before you act" was four separate
# commands, and an instruction that costs four commands gets skipped. It costs
# one. The operator is required to run it before every claim and every action;
# a human can run it for the same reason.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPE="$REPO_ROOT/.pipeline"
BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; OFF=""; }

section() { printf '\n%s\n' "${BOLD}$*${OFF}"; }

section "репозиторий"
git -C "$REPO_ROOT" log -1 --format='  HEAD  %h %s (%ar)'
dirty="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -z "$dirty" ]]; then
  printf '  дерево чистое — свежий слайс запускать можно\n'
else
  printf '  дерево ГРЯЗНОЕ — свежий слайс здесь не стартует:\n'
  printf '%s\n' "$dirty" | sed 's/^/    /'
fi

section "слайс в работе"
if [[ -f "$PIPE/slice.json" ]]; then
  node -e 'const j=require(process.argv[1]);
    console.log("  "+j.id+"  "+j.title);
    console.log("  статус: "+j.status+"   ревизия: "+j.revision);
    if (j.blocked_on) j.blocked_on.forEach(q=>console.log("  ждёт решения: "+q.slice(0,120)));
  ' "$PIPE/slice.json"
  for f in plan-verdict code-verdict; do
    if [[ -f "$PIPE/$f.json" ]]; then
      node -e 'const j=require(process.argv[1]);
        console.log("  "+process.argv[2]+": "+j.verdict
          +(j.revision!==undefined?" (по ревизии "+j.revision+")":"")
          +"  вопросов/замечаний: "+((j.questions||j.findings||[]).length));' "$PIPE/$f.json" "$f"
    fi
  done
  [[ -f "$PIPE/coder-report.md" ]] && printf '  отчёт кодера есть → фаза кода или посадки\n'
  [[ -f "$PIPE/answer.md" ]] && printf '  %s\n' "ответ человека ЖДЁТ доставки (.pipeline/answer.md)"
else
  printf '  нет активного слайса — .pipeline/ пуст\n'
fi

section "последние прогоны"
ls -1t "$PIPE/runs" 2>/dev/null | head -4 | sed 's/^/  /' || printf '  нет архивов\n'

section "агенты"
paseo ls -g --label pipeline=openebfd 2>/dev/null | tail -n +2 \
  | awk '{printf "  %-10s %-20s %s\n", $1, $2, $5}' || printf '  демон недоступен\n'

section "скрипты"
if scripts="$(paseo script ls --json 2>/dev/null)"; then
  printf '%s' "$scripts" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    JSON.parse(s).filter(x=>x.lifecycle!=="stopped"||x.terminalId)
      .forEach(x=>console.log("  "+x.scriptName.padEnd(14)+x.lifecycle
        +(x.exitCode!==null?"  exit="+x.exitCode:"")
        +(x.terminalId?"  терминал "+x.terminalId.slice(0,8):"")));
    })'
  printf '%s' "$scripts" | grep -q '"lifecycle": *"running"' \
    && printf '  %s\n' "ПРОГОН ИДЁТ — не трогай дерево и не запускай второй" \
    || printf '  ничего не запущено\n'
else
  printf '  демон недоступен\n'
fi
printf '\n'
