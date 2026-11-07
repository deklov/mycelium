#!/usr/bin/env bash
# record.sh: commit, tag and push a finished experiment as a node (DESIGN 6, 10).
# Record EVERY experiment, including failures; the tree is the shared memory.
#
#   record.sh --worktree <path> --summary "<one line>" \
#             (--description "<text>" | --description-file <file>) \
#             [--claim <claim_id>] [--failed] [--keep]
#
#   --failed   the change did not build/run, or you gave up on it; no score is recorded
#   --keep     keep the worktree afterwards (default: remove it)
#   --allow-binary  allow adding new binary files (refused by default: they are
#              almost always build outputs; add them to ignore_paths instead)
#   --root     (onboarding only) record the worktree's commit as this run's root node
#
# The score is taken from evaluate.sh's result for exactly the tree being
# committed; run evaluate.sh first (not needed with --failed). The parents are
# the worktree's HEAD plus any merge in progress, and must all be nodes.
# Status (improved / no_improvement) is computed against the best parent,
# using the noise threshold. If --claim is given, the claim is released after
# the node is pushed.

source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

wt="" summary="" desc="" claim="" failed=0 keep=0 root=0 allow_binary=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --description) desc="$2"; shift 2 ;;
    --description-file) desc="$(cat "$2")"; shift 2 ;;
    --claim) claim="$2"; shift 2 ;;
    --failed) failed=1; shift ;;
    --keep) keep=1; shift ;;
    --allow-binary) allow_binary=1; shift ;;
    --root) root=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1" ;;
  esac
done
[ -n "$wt" ] && [ -d "$wt" ] || usage 1
[ -n "$summary" ] || die "--summary is required"
[ -n "$desc" ] || die "a description is required: what you tried, why, and what you learned"
case "$summary" in *"
"*) die "--summary must be one line" ;; esac
wt="$(cd "$wt" && pwd)"
load_run
load_agent
require_target
[ -z "$claim" ] || require_id claim_id "$claim"
fetch_target

# ---- the tree being recorded and its score
idx="$(mktemp "${TMPDIR:-/tmp}/mycelium_idx.XXXXXX")"; rm -f "$idx"
GIT_INDEX_FILE="$idx" git -C "$wt" read-tree HEAD
GIT_INDEX_FILE="$idx" git -C "$wt" add -A .
tree="$(GIT_INDEX_FILE="$idx" git -C "$wt" write-tree)"
rm -f "$idx"

score="" score_runs=""
if [ "$failed" -eq 0 ]; then
  result="$WORK_DIR/eval/$tree.result"
  [ -f "$result" ] || die "no evaluation for the current worktree contents (tree ${tree:0:12}); run scripts/evaluate.sh $wt first, or pass --failed"
  if [ "$(cut -f1 "$result")" = failed ]; then
    info "the last evaluation of this tree failed; recording as failed"
    failed=1
  else
    score="$(cut -f2 "$result")"
    score_runs="$(cut -f6 "$result")"
  fi
fi

# ---- parents
head_sha="$(git -C "$wt" rev-parse HEAD)"
parent_shas="$head_sha"
merge_head_file="$(git -C "$wt" rev-parse --git-path MERGE_HEAD)"
case "$merge_head_file" in /*) ;; *) merge_head_file="$wt/$merge_head_file" ;; esac
if [ -f "$merge_head_file" ]; then
  [ -z "$(git -C "$wt" diff --name-only --diff-filter=U)" ] || die "unresolved merge conflicts in $wt"
  parent_shas="$parent_shas $(tr '\n' ' ' < "$merge_head_file")"
fi

node_of_sha() {
  tgit for-each-ref --points-at "$1" "$NODE_PREFIX" --format='%(refname:lstrip=5)' | head -n 1
}

parents=""
if [ "$root" -eq 1 ]; then
  [ ! -f "$merge_head_file" ] || die "--root cannot record a merge"
  ! tgit rev-parse -q --verify "${NODE_PREFIX}root" >/dev/null || die "run $RUN_ID already has a root node"
  [ "$failed" -eq 0 ] || die "the baseline must score; fix score.sh first"
else
  for s in $parent_shas; do
    p="$(node_of_sha "$s")"
    [ -n "$p" ] || die "worktree parent ${s:0:12} is not a node of run $RUN_ID (use scripts/checkout.sh)"
    parents="${parents:+$parents,}$p"
  done
  root_sha="$(tgit rev-parse -q --verify "${NODE_PREFIX}root^{commit}")" || die "run $RUN_ID has no root node"
  bad="$(protected_paths_changed "$root_sha" "$tree")"
  [ -z "$bad" ] || die "the change touches protected path '$bad' (see task/config.yaml); revert it"
fi

# ---- status
if [ "$root" -eq 1 ]; then status=baseline
elif [ "$failed" -eq 1 ]; then status=failed
else
  best_parent="$(node_table | awk -F'\t' -v ps=",$parents," -v dir="$DIRECTION" '
    index(ps, "," $1 ",") && $4 != "" && $13 == "" {
      if (best == "" || (dir == "higher" ? $4 + 0 > best + 0 : $4 + 0 < best + 0)) best = $4 }
    END { print best }')"
  if [ -z "$best_parent" ]; then
    best_parent="$(node_table | awk -F'\t' '$1 == "root" { print $4 }')"
  fi
  status="$(awk -v s="$score" -v b="$best_parent" -v n="$(noise_at "$best_parent")" -v dir="$DIRECTION" 'BEGIN {
    d = (dir == "higher") ? s - b : b - s
    print (b == "" || d > n) ? "improved" : "no_improvement" }')"
fi

# ---- commit, tag, push
git_id=(-c "user.name=$(git -C "$wt" config user.name || echo "mycelium $AGENT_ID")"
        -c "user.email=$(git -C "$wt" config user.email || echo "$AGENT_ID@mycelium.invalid")")

write_message() { # NODE_ID
  {
    printf '%s\n\n' "$summary"
    printf '%s\n\n' "$desc"
    echo "Mycelium-Run: $RUN_ID"
    echo "Mycelium-Node: $1"
    if [ -n "$parents" ]; then for p in $(printf '%s' "$parents" | tr ',' ' '); do echo "Mycelium-Parent: $p"; done; fi
    [ -z "$claim" ] || echo "Mycelium-Claim: $claim"
    [ -z "$score" ] || echo "Mycelium-Score: $score"
    [ -z "$score_runs" ] || echo "Mycelium-Score-Runs: $score_runs"
    echo "Mycelium-Status: $status"
    echo "Mycelium-Agent-Id: $AGENT_ID"
    echo "Mycelium-Agent: $AGENT_KIND"
    echo "Mycelium-Model: $MODEL"
    echo "Mycelium-Machine: $MACHINE"
    echo "Mycelium-Seed: $SEED"
    [ -z "$DATA_VERSION" ] || echo "Mycelium-Data-Version: $DATA_VERSION"
  } > "$msg"
}

msg="$(mktemp "${TMPDIR:-/tmp}/mycelium_msg.XXXXXX")"
trap 'rm -f "$msg"' EXIT
if [ "$root" -eq 1 ]; then node_id=root; else node_id="${AGENT_ID}_$(stamp)"; fi
write_message "$node_id"

git -C "$wt" add -A .
if [ "$allow_binary" -eq 0 ]; then
  bins="$(git -C "$wt" diff --cached --numstat --diff-filter=A HEAD | awk -F'\t' '$1 == "-" && $2 == "-" { print "  " $3 }')"
  if [ -n "$bins" ]; then
    git -C "$wt" reset -q
    die "the change adds binary files, which are almost always build outputs:
$bins
Delete them (and evaluate again), or list them in ignore_paths in task/config.yaml; pass --allow-binary only if they are real sources."
  fi
fi
if [ "$failed" -eq 0 ] && [ "$(git -C "$wt" write-tree)" != "$tree" ]; then
  die "the worktree changed after it was evaluated; evaluate again"
fi
git -C "$wt" "${git_id[@]}" commit --quiet --no-verify --allow-empty -F "$msg"
sha="$(git -C "$wt" rev-parse HEAD)"

attempt=0
while :; do
  tag="${NODE_PREFIX}$node_id"
  if tgit rev-parse -q --verify "$tag" >/dev/null; then
    out="tag exists locally"; rc=1
  else
    tgit update-ref "$tag" "$sha"
    rc=0; out="$(tgit push --porcelain origin "$tag:$tag" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && break
    tgit update-ref -d "$tag"
  fi
  if printf '%s' "$out" | grep -qE 'already exists|\[rejected\]|exists locally' && [ "$root" -eq 0 ] && [ $attempt -lt 5 ]; then
    attempt=$((attempt + 1))
    node_id="${AGENT_ID}_$(stamp)_$attempt"
    info "node ID taken; retrying as $node_id"
    write_message "$node_id"
    git -C "$wt" "${git_id[@]}" commit --quiet --no-verify --amend --allow-empty -F "$msg"
    sha="$(git -C "$wt" rev-parse HEAD)"
    continue
  fi
  printf '%s\n' "$out" >&2
  die "could not push node $node_id. The commit is ${sha:0:12} in $wt; fix the problem and push with:
  git -C $TARGET_DIR tag $tag $sha && git -C $TARGET_DIR push origin $tag"
done

info "recorded node $node_id: ${score:-no score} ($status), parents ${parents:-none}"

if [ -n "$claim" ] && [ -z "${MYCELIUM_TEST_SKIP_RELEASE:-}" ]; then
  "$SCRIPTS_DIR/claim.sh" release "$claim" || warn "could not release claim $claim; it will expire (and the node marks it done)"
fi
if [ "$keep" -eq 0 ] && [ "$root" -eq 0 ]; then
  tgit worktree remove --force "$wt" 2>/dev/null || warn "could not remove worktree $wt"
fi
echo "$node_id"
