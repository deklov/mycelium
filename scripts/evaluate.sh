#!/usr/bin/env bash
# evaluate.sh <worktree>: score the current contents of a target worktree with
# the fixed task/score.sh. Always use this; never measure the score yourself.
#
# What it does:
#   1. Snapshots the worktree (tracked + untracked, respecting .gitignore) as a Git tree.
#   2. Exports that exact tree to a temp dir and restores every protected path
#      from the root node, so edits to protected files cannot affect the score.
#   3. Runs task/score.sh <dir> with MYCELIUM_SEED, MYCELIUM_BUDGET_SECONDS and
#      MYCELIUM_TASK_DIR set, under a timeout and (optionally) a machine-wide lock
#      given by MYCELIUM_SCORE_LOCK, so that benchmarks never run concurrently.
#   4. Repeats step 3 eval_repeats times (config, default 3; env
#      MYCELIUM_EVAL_REPEATS overrides) and takes the median, which damps timing
#      noise. If any repeat fails, the evaluation fails. The lock is taken per
#      repeat, so repeats of different agents interleave.
#   5. Saves the result keyed by the tree hash; record.sh only accepts a score
#      that evaluate.sh produced for exactly the tree being committed.
#
# Output: the (median) score on the last line of stdout, or "failed" (exit 1).
# The full log, with every repeat, is in .work/eval/<tree>.log.

source "$(dirname "$0")/lib/common.sh"

wt="${1:-}"; [ -n "$wt" ] && [ -d "$wt" ] || die "usage: evaluate.sh <worktree>"
wt="$(cd "$wt" && pwd)"
load_run
load_agent
require_target

tree_of_worktree() { # print the tree hash of the worktree's current contents
  local idx
  idx="$(mktemp "${TMPDIR:-/tmp}/mycelium_idx.XXXXXX")"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$1" read-tree HEAD
  GIT_INDEX_FILE="$idx" git -C "$1" add -A .
  GIT_INDEX_FILE="$idx" git -C "$1" write-tree
  rm -f "$idx"
}

tree="$(tree_of_worktree "$wt")"
mkdir -p "$WORK_DIR/eval"
log="$WORK_DIR/eval/$tree.log"
result="$WORK_DIR/eval/$tree.result"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mycelium_eval.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src"
git -C "$wt" archive "$tree" | tar -x -C "$tmp/src"

root_sha="$(tgit rev-parse -q --verify "refs/tags/mycelium/$RUN_ID/node/root^{commit}" 2>/dev/null || true)"
if [ -n "$root_sha" ]; then
  # remove the candidate's version of every protected file, then restore the root's
  git -C "$wt" ls-tree -r --name-only "$tree" | protected_filter | while IFS= read -r p; do rm -f "$tmp/src/$p"; done
  tgit ls-tree -r --name-only "$root_sha" | protected_filter > "$tmp/protected"
  if [ -s "$tmp/protected" ]; then
    tr '\n' '\0' < "$tmp/protected" | xargs -0 git -C "$TARGET_DIR" archive "$root_sha" -- | tar -x -C "$tmp/src"
  fi
fi

score_script="$MYCELIUM_ROOT/task/score.sh"
[ -x "$score_script" ] || die "task/score.sh is missing or not executable"
limit="$(cfg eval_timeout_seconds $((2 * EVAL_BUDGET)))"

run_score() {
  local cmd=("$score_script" "$tmp/src")
  if command -v timeout >/dev/null 2>&1; then cmd=(timeout "$limit" "${cmd[@]}"); fi
  if [ -n "${MYCELIUM_SCORE_LOCK:-}" ] && command -v flock >/dev/null 2>&1; then
    echo "[evaluate] waiting for score lock $MYCELIUM_SCORE_LOCK" >&2
    cmd=(flock "$MYCELIUM_SCORE_LOCK" "${cmd[@]}")
  fi
  ( cd "$tmp/src" && MYCELIUM_SEED="$SEED" MYCELIUM_BUDGET_SECONDS="$EVAL_BUDGET" \
      MYCELIUM_TASK_DIR="$MYCELIUM_ROOT/task" MYCELIUM_DATA_VERSION="$DATA_VERSION" "${cmd[@]}" )
}

repeats="${MYCELIUM_EVAL_REPEATS:-$(cfg eval_repeats 3)}"
case "$repeats" in ''|*[!0-9]*|0) die "eval_repeats must be a positive integer (got '$repeats')" ;; esac
is_number() { printf '%s' "$1" | grep -Eq '^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$'; }

info "scoring tree ${tree:0:12}, $repeats repeat(s) (log: $log)"
: > "$log"
runs="" rc=0 start="$(date +%s)"
for r in $(seq 1 "$repeats"); do
  rc=0; t0="$(date +%s)"
  run_score > "$tmp/out" 2> "$tmp/err" || rc=$?
  { echo "=== repeat $r of $repeats"; echo "== stdout"; cat "$tmp/out"; echo "== stderr"; cat "$tmp/err"
    echo "== exit $rc after $(( $(date +%s) - t0 ))s"; } >> "$log"
  s="$(grep -v '^[[:space:]]*$' "$tmp/out" | tail -n 1 | tr -d '[:space:]' || true)"
  if [ "$rc" -ne 0 ] || ! is_number "$s"; then [ "$rc" -ne 0 ] || rc=1; break; fi
  runs="${runs:+$runs,}$s"
  [ "$repeats" -eq 1 ] || info "repeat $r: $s"
done
elapsed=$(( $(date +%s) - start ))

if [ "$rc" -eq 0 ]; then
  score="$(printf '%s' "$runs" | tr ',' '\n' | sort -g | awk '{ a[NR] = $1 } END { print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }')"
  printf 'ok\t%s\t%s\t%s\t%s\t%s\n' "$score" "$SEED" "$(now)" "$MACHINE" "$runs" > "$result"
  info "score $score${runs:+ (median of $runs)} (${elapsed}s)"
  echo "$score"
else
  printf 'failed\t\t%s\t%s\t%s\t%s\n' "$SEED" "$(now)" "$MACHINE" "$runs" > "$result"
  [ "$rc" -ne 124 ] || warn "score.sh timed out after ${limit}s"
  warn "scoring failed (exit $rc, repeat $r of $repeats); last lines of the log:"
  tail -n 15 "$log" >&2
  echo "failed"
  exit 1
fi
