#!/usr/bin/env bash
# onboard.sh: helpers for onboarding mode (DESIGN 11). Onboarding is resumable:
# `status` reports which steps are done, so an agent continues from the first
# missing one.
#
#   onboard.sh status        which onboarding steps are done
#   onboard.sh noise [N]     score the baseline N times (default 5); report the noise
#   onboard.sh root          score the baseline and record it as this run's root node
#   onboard.sh ready         tag the Mycelium repo mycelium/<run_id>/ready and push it

source "$(dirname "$0")/lib/common.sh"

cmd="${1:-status}"; shift || true
cd "$MYCELIUM_ROOT"

baseline_worktree() { # create a fresh worktree at the submodule's pinned commit
  local wt
  mkdir -p "$WORK_DIR/onboarding"
  wt="$WORK_DIR/onboarding/baseline_$(date +%s)_$$"
  tgit worktree add --quiet --detach "$wt" HEAD >&2
  echo "$wt"
}

case "$cmd" in
  status)
    step() { printf '  [%s] %s\n' "$1" "$2"; }
    run_id="${MYCELIUM_RUN_ID:-$(cfg run_id)}"
    echo "Onboarding status for $(basename "$MYCELIUM_ROOT")"
    sub_url="$(git config -f .gitmodules submodule.target.url 2>/dev/null || true)"
    fork="$(cfg target_fork '')"
    if [ ! -e "$TARGET_DIR/.git" ]; then
      step " " "1. target: fork it and add the fork as the submodule target/"
    elif [ -z "$fork" ] || [ "$sub_url" != "$fork" ]; then
      step " " "1. target: submodule points at $sub_url, but target_fork in config.yaml is '${fork}'. Fork the target, then: git submodule set-url target <fork> && git submodule sync && git -C target fetch origin"
    else
      step x "1. target: exploration fork $fork at $(tgit rev-parse --short HEAD)"
    fi
    if grep -q 'Placeholder' task/TASK.md 2>/dev/null; then step " " "2. task/TASK.md written"
    else step x "2. task/TASK.md written"; fi
    if grep -q 'has not been written yet' task/score.sh 2>/dev/null; then step " " "3. task/score.sh written"
    else step x "3. task/score.sh written"; fi
    if [ "$(cfg noise_threshold 0)" = 0 ]; then step " " "3. noise measured (noise_threshold in config.yaml is 0)"
    else step x "3. noise measured: noise_threshold $(cfg noise_threshold)"; fi
    if [ -n "$run_id" ]; then step x "4. run_id: $run_id"; else step " " "4. run_id chosen"; fi
    if [ -n "$run_id" ] && [ -e "$TARGET_DIR/.git" ] && \
       tgit ls-remote --exit-code --tags origin "refs/tags/mycelium/$run_id/node/root" >/dev/null 2>&1; then
      step x "5. root node mycelium/$run_id/node/root"
    else step " " "5. baseline scored and root node created (onboard.sh root)"; fi
    step "-" "6-7. pilot (optional; recommended for a new score.sh or a vague TASK.md)"
    if [ -n "$run_id" ] && mgit ls-remote --exit-code --tags origin "refs/tags/mycelium/$run_id/ready" >/dev/null 2>&1; then
      step x "8. run marked ready (mycelium/$run_id/ready)"
    else step " " "8. run marked ready (onboard.sh ready)"; fi
    ;;

  noise)
    n="${1:-5}"
    require_target
    export MYCELIUM_RUN_ID="${MYCELIUM_RUN_ID:-$(cfg run_id noise_check)}"
    load_run
    wt="$(baseline_worktree)"
    scores=""
    for i in $(seq 1 "$n"); do
      s="$("$SCRIPTS_DIR/evaluate.sh" "$wt" 2>/dev/null | tail -n 1)" || true
      echo "  run $i: $s"
      [ "$s" != failed ] || { tgit worktree remove --force "$wt"; die "the baseline failed to score; see .work/eval/*.log"; }
      scores="$scores $s"
    done
    tgit worktree remove --force "$wt"
    printf '%s\n' $scores | awk '
      { x[NR] = $1; s += $1; if (NR == 1 || $1 < mn) mn = $1; if (NR == 1 || $1 > mx) mx = $1 }
      END { m = s / NR; for (i = 1; i <= NR; i++) v += (x[i] - m) ^ 2; sd = (NR > 1) ? sqrt(v / (NR - 1)) : 0
            printf "mean %.6g  stddev %.4g (%.2f%%)  min %.6g  max %.6g  range %.4g\n", m, sd, (m != 0 ? 100 * sd / m : 0), mn, mx, mx - mn
            t = 3 * sd; if (mx - mn > t) t = mx - mn
            printf "suggested noise_threshold: %.4g (absolute: the larger of 3 x stddev and the observed range)\n", t
            if (m != 0) printf "  or, with noise_mode: relative, noise_threshold: %.4g (%.2f%% of the score)\n", t / (m < 0 ? -m : m), 100 * t / (m < 0 ? -m : m)
            print "Use relative if the noise grows with the score (e.g. a speedup or a time); absolute if it does not." }'
    ;;

  root)
    require_target
    load_run
    load_agent
    if tgit rev-parse -q --verify "${NODE_PREFIX}root" >/dev/null; then die "run $RUN_ID already has a root node"; fi
    wt="$(baseline_worktree)"
    s="$("$SCRIPTS_DIR/evaluate.sh" "$wt" | tail -n 1)" || die "the baseline failed to score"
    "$SCRIPTS_DIR/record.sh" --root --worktree "$wt" --summary "Baseline" \
      --description "The unmodified target at $(tgit rev-parse --short HEAD), scored with the fixed task/score.sh before exploration starts." >/dev/null
    tgit worktree remove --force "$wt" 2>/dev/null || true
    info "root node of run $RUN_ID recorded with score $s"
    ;;

  ready)
    require_target
    load_run
    tgit rev-parse -q --verify "${NODE_PREFIX}root" >/dev/null || die "run $RUN_ID has no root node yet (onboard.sh root)"
    [ -z "$(mgit status --porcelain -- task CLAUDE.md skills scripts hooks .gitmodules target)" ] \
      || die "commit the task files (and submodule) before marking the run ready"
    mgit push --quiet origin HEAD
    mgit tag "$READY_TAG"
    mgit push --quiet origin "refs/tags/$READY_TAG"
    info "run $RUN_ID is ready: start agents with scripts/launch.sh"
    ;;

  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
