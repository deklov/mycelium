#!/usr/bin/env bash
# launch.sh: start an exploring agent on this machine (DESIGN 12).
#
#   scripts/launch.sh [options]
#
#   --headless             run unattended: a fresh agent process per experiment
#                          (fresh context each time, DESIGN 16 item 3). This skips
#                          the agent's permission prompts, so only use it in a
#                          sandbox such as a container or VM.
#   --agent claude|codex   which agent CLI to run (default: claude). For anything
#                          else set MYCELIUM_AGENT_CMD to a shell command; the
#                          prompt is in $MYCELIUM_PROMPT.
#   --model <model>        model to pass to the agent and record in nodes
#   --max-experiments <n>  stop after n iterations (default: max_experiments_per_agent, or unlimited)
#   --max-hours <h>        stop after h hours (default: max_hours, or unlimited)
#   --agent-id <id>        use this agent ID instead of <hostname>_<n>
#   --print-env            print the environment for this agent and exit
#   --allow-unready        do not require the ready tag (onboarding pilots only)
#
# Each headless iteration is killed after iteration_timeout_seconds (config,
# default 3600) so one hung agent cannot stall the machine.
#
# Headless mode also:
#   - runs scripts/verify.sh --next before every verify_every-th iteration
#     (config, default 1; 0 disables), so every agent verifies other agents'
#     best nodes. Verification is mechanical, so no LLM is involved.
#
# Stop gracefully: touch .work/STOP (all agents on this machine) or
# .work/<agent_id>/STOP; the current experiment finishes first.

source "$(dirname "$0")/lib/common.sh"

headless=0 agent=claude model="${MYCELIUM_MODEL:-}" max_exp="" max_hours="" agent_id="" print_env=0 allow_unready=0
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) headless=1; shift ;;
    --agent) agent="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --max-experiments) max_exp="$2"; shift 2 ;;
    --max-hours) max_hours="$2"; shift 2 ;;
    --agent-id) agent_id="$2"; shift 2 ;;
    --print-env) print_env=1; shift ;;
    --allow-unready) allow_unready=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

cd "$MYCELIUM_ROOT"
git config core.hooksPath hooks
[ -e "$TARGET_DIR/.git" ] || git submodule update --init --quiet target
load_run
[ -n "$max_exp" ] || max_exp="$(cfg max_experiments_per_agent '')"
[ -n "$max_hours" ] || max_hours="$(cfg max_hours '')"

# ---- the run must be marked ready
if [ "$allow_unready" -eq 0 ]; then
  if ! mgit ls-remote --exit-code --tags origin "refs/tags/$READY_TAG" >/dev/null 2>&1; then
    die "run $RUN_ID is not marked ready (no tag $READY_TAG on origin). Finish onboarding first: start the agent in this directory without launch.sh."
  fi
fi

# ---- push access to both remotes
if [ -z "${MYCELIUM_SKIP_PUSH_CHECK:-}" ]; then
  mgit push --dry-run --no-verify --quiet origin "HEAD:refs/heads/mycelium/$RUN_ID/push_check" >/dev/null 2>&1 \
    || die "cannot push to the Mycelium repo's origin ($(mgit remote get-url origin))"
  tgit push --dry-run --no-verify --quiet origin "HEAD:refs/heads/mycelium/$RUN_ID/push_check" >/dev/null 2>&1 \
    || die "cannot push to the target's origin ($(tgit remote get-url origin))"
fi

# ---- agent ID: <hostname>_<n>, unique on this machine while running
machine="${MYCELIUM_MACHINE:-$(sanitize_id "$(hostname -s 2>/dev/null || hostname)")}"
mkdir -p "$WORK_DIR/agents"
if [ -z "$agent_id" ]; then
  n=1
  while :; do
    agent_id="${machine}_$n"
    lock="$WORK_DIR/agents/$agent_id"
    if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; break; fi
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then echo $$ > "$lock/pid"; break; fi
    n=$((n + 1))
  done
  [ "$print_env" -eq 1 ] || trap 'rm -rf "$WORK_DIR/agents/$agent_id"' EXIT
fi
require_id agent_id "$agent_id"

case "$agent" in claude) kind=claude_code ;; codex) kind=codex ;; *) kind="$(sanitize_id "$agent")" ;; esac
export MYCELIUM_RUN_ID="$RUN_ID" MYCELIUM_AGENT_ID="$agent_id" MYCELIUM_MACHINE="$machine" \
       MYCELIUM_AGENT="$kind" MYCELIUM_MODEL="${model:-unknown}" MYCELIUM_MODE=exploring

if [ "$print_env" -eq 1 ]; then
  for v in MYCELIUM_RUN_ID MYCELIUM_AGENT_ID MYCELIUM_MACHINE MYCELIUM_AGENT MYCELIUM_MODEL MYCELIUM_MODE; do
    printf 'export %s=%q\n' "$v" "${!v}"
  done
  exit 0
fi

info "agent $agent_id ($kind${model:+, $model}) exploring run $RUN_ID"

prompt_for() { # ITERATION
  cat <<EOF
You are Mycelium exploring agent $agent_id, iteration $1${max_exp:+ of $max_exp}, in run $RUN_ID.
Read CLAUDE.md (exploring mode) and skills/mycelium/SKILL.md, then run exactly ONE
iteration of the experiment loop from start to finish: read the tree, choose, claim,
change, evaluate, record (even if it failed) and release. Then stop.
Nobody is watching: do not ask questions, decide for yourself.
EOF
}

tmo=()   # set to a timeout command for headless iterations
run_agent() { # PROMPT [interactive]
  export MYCELIUM_PROMPT="$1"
  if [ -n "${MYCELIUM_AGENT_CMD:-}" ]; then ${tmo[@]+"${tmo[@]}"} bash -c "$MYCELIUM_AGENT_CMD"; return; fi
  case "$agent" in
    claude)
      if [ "${2:-}" = interactive ]; then claude ${model:+--model "$model"} "$1"
      else ${tmo[@]+"${tmo[@]}"} claude -p --dangerously-skip-permissions ${model:+--model "$model"} "$1"; fi ;;
    codex)
      if [ "${2:-}" = interactive ]; then codex ${model:+-m "$model"} "$1"
      else ${tmo[@]+"${tmo[@]}"} codex exec --dangerously-bypass-approvals-and-sandbox ${model:+-m "$model"} "$1"; fi ;;
    *) die "unknown agent '$agent'; set MYCELIUM_AGENT_CMD" ;;
  esac
}

if [ "$headless" -eq 0 ]; then
  run_agent "You are Mycelium exploring agent $agent_id in run $RUN_ID. Read CLAUDE.md and skills/mycelium/SKILL.md and start the exploring loop." interactive
  exit $?
fi

start="$(date +%s)"
iter_timeout="${MYCELIUM_ITERATION_TIMEOUT:-$(cfg iteration_timeout_seconds 3600)}"
if command -v timeout >/dev/null 2>&1; then tmo=(timeout --kill-after=60 "$iter_timeout"); fi
mkdir -p "$WORK_DIR/$agent_id/logs"
verify_every="$(cfg verify_every 1)"
i=0
while :; do
  i=$((i + 1))
  if [ -n "$max_exp" ] && [ "$i" -gt "$max_exp" ]; then info "reached $max_exp experiments"; break; fi
  if [ -n "$max_hours" ] && [ "$(awk -v s="$start" -v n="$(date +%s)" -v h="$max_hours" 'BEGIN { print (n - s > h * 3600) }')" = 1 ]; then
    info "reached the time budget of $max_hours h"; break
  fi
  if [ -e "$WORK_DIR/STOP" ] || [ -e "$WORK_DIR/$agent_id/STOP" ]; then info "stop file found"; break; fi
  log="$WORK_DIR/$agent_id/logs/iteration_$(printf '%03d' "$i").log"
  if [ "${verify_every:-0}" -gt 0 ] && [ $(( (i - 1) % verify_every )) -eq 0 ]; then
    vlog="$WORK_DIR/$agent_id/logs/verify_$(printf '%03d' "$i").log"
    vrc=0; "$SCRIPTS_DIR/verify.sh" --next > "$vlog" 2>&1 || vrc=$?
    case "$vrc" in
      0) info "verified: $(grep '^mycelium: verified' "$vlog" | tail -n 1 | sed 's/^mycelium: //')" ;;
      4) ;;
      *) warn "verify.sh --next failed with status $vrc (see $vlog)" ;;
    esac
  fi
  info "iteration $i (log: $log)"
  rc=0
  run_agent "$(prompt_for "$i")" > "$log" 2>&1 || rc=$?
  [ "$rc" -ne 124 ] || echo "[launch] iteration timed out after ${iter_timeout}s" >> "$log"
  [ "$rc" -eq 0 ] || warn "agent exited with status $rc in iteration $i (see $log)"
  "$SCRIPTS_DIR/checkout.sh" --clean >/dev/null 2>&1 || true
done
info "agent $agent_id finished after $((i - 1)) iterations"
