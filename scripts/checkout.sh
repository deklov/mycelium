#!/usr/bin/env bash
# checkout.sh <node_id> [<node_id>...]: create a fresh worktree of the target at a node.
#
# With one node, the worktree is a detached checkout of that node: extend it.
# With several nodes, the first is checked out and the others are merged into
# it without committing (a merge node). Resolve any conflicts, then evaluate
# and record as usual; record.sh picks up all parents from the merge state.
#
# Prints the worktree path on stdout. Each agent gets its own worktrees under
# .work/<agent_id>/, so agents never interfere, even on one machine.
#
#   checkout.sh --clean    remove all of this agent's worktrees

source "$(dirname "$0")/lib/common.sh"

[ $# -gt 0 ] || die "usage: checkout.sh <node_id> [<node_id>...] | --clean"
load_run
load_agent
require_target

if [ "$1" = --clean ]; then
  for d in "$WORK_DIR/$AGENT_ID"/wt_*; do
    [ -d "$d" ] || continue
    tgit worktree remove --force "$d" 2>/dev/null || rm -rf "$d"
  done
  tgit worktree prune
  info "removed worktrees of $AGENT_ID"
  exit 0
fi

# ignore_paths from config.yaml: build outputs that must never be recorded
ign="$(cfg_list ignore_paths)"
if [ -n "$ign" ]; then
  excl="$(tgit rev-parse --git-common-dir)/info/exclude"
  case "$excl" in /*) ;; *) excl="$TARGET_DIR/$excl" ;; esac
  mkdir -p "$(dirname "$excl")"; touch "$excl"
  printf '%s\n' "$ign" | while IFS= read -r p; do grep -qxF "$p" "$excl" || printf '%s\n' "$p" >> "$excl"; done
fi

fetch_target
shas=()
for n in "$@"; do
  require_id node_id "$n"
  s="$(tgit rev-parse -q --verify "refs/tags/mycelium/$RUN_ID/node/$n^{commit}" 2>/dev/null)" || die "no node $n in run $RUN_ID"
  shas+=("$s")
done

mkdir -p "$WORK_DIR/$AGENT_ID"
wt="$WORK_DIR/$AGENT_ID/wt_$(stamp)_$$"
tgit worktree add --quiet --detach "$wt" "${shas[0]}" >&2

if [ ${#shas[@]} -gt 1 ]; then
  rc=0
  git -C "$wt" -c user.name="mycelium $AGENT_ID" -c user.email="$AGENT_ID@mycelium.invalid" \
    merge --no-commit --no-ff --quiet "${shas[@]:1}" >&2 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "merge has conflicts; resolve them in $wt before evaluating:"
    git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/  /' >&2
  else
    info "merged $* without conflicts"
  fi
fi
echo "$wt"
