#!/usr/bin/env bash
# verify.sh <node_id>: re-run the score on an existing node (DESIGN 16, item 1).
#
# Claims the verification (kind verify), checks the node out in a fresh
# worktree, scores it with evaluate.sh, and pushes an annotated tag
#   mycelium/<run_id>/verify/<node_id>/<agent_id>
# whose message carries the reproduced score as trailers. Then releases the claim.
#
#   verify.sh --next   pick the node most worth verifying and verify it: the
#                      best-ranked node, among the top verify_top (config,
#                      default 5) by effective score, plus root, that is
#                      unverified or inherits_suspect, not your own and not
#                      being verified. launch.sh runs this automatically
#                      (verify_every in config.yaml).
#
# Exit codes: 0 verified (or reproduction recorded), 4 nothing to do (already
# verified by you, being verified by someone else, or your own node).

source "$(dirname "$0")/lib/common.sh"

node="${1:-}"; [ -n "$node" ] || die "usage: verify.sh <node_id> | --next"

if [ "$node" = --next ]; then
  load_run
  load_agent
  require_target
  fetch_target
  sort_dir=""; [ "$DIRECTION" = higher ] && sort_dir=r
  top="$(cfg verify_top 5)"
  cands="$(ranked_table | awk -F'\t' '$16 != "" && $15 != "invalid" && $15 != "failed"' | sort -t "$(printf '\t')" -k16,16g$sort_dir \
    | awk -F'\t' -v me="$AGENT_ID" -v top="$top" '
        { rank++ }
        (rank <= top || $1 == "root") && ($15 == "unverified" || $15 == "inherits_suspect") && $6 != me { print $1 }')"
  [ -n "$cands" ] || { info "nothing worth verifying right now"; exit 4; }
  for c in $cands; do
    rc=0; "$0" "$c" || rc=$?
    [ "$rc" -eq 4 ] || exit "$rc"
  done
  info "nothing worth verifying right now"
  exit 4
fi
require_id node_id "$node"
load_run
load_agent
require_target
fetch_target
fetch_branch "$CLAIMS_BRANCH"

row="$(node_table | awk -F'\t' -v id="$node" '$1 == id')"
[ -n "$row" ] || die "no node $node in run $RUN_ID"
[ -z "$(printf '%s' "$row" | cut -f13)" ] || die "node $node is invalid: $(printf '%s' "$row" | cut -f13)"
[ "$(printf '%s' "$row" | cut -f5)" != failed ] || { info "node $node failed; there is no score to verify"; exit 4; }
author="$(printf '%s' "$row" | cut -f6)"
recorded="$(printf '%s' "$row" | cut -f4)"
sha="$(printf '%s' "$row" | cut -f2)"
if [ "$author" = "$AGENT_ID" ]; then info "node $node is your own; another agent must verify it"; exit 4; fi
tag="${VERIFY_PREFIX}$node/$AGENT_ID"
if tgit rev-parse -q --verify "$tag" >/dev/null; then info "you already verified $node"; exit 4; fi
other="$(claims_table | awk -F'\t' -v n="$node" '$9 == "open" && $2 == "verify" && $4 == n { print $3; exit }')"
if [ -n "$other" ]; then info "$other is already verifying $node"; exit 4; fi

rc=0
claim="$("$SCRIPTS_DIR/claim.sh" new --kind verify --node "$node" \
  --description "Re-run the fixed score on node $node to check its recorded score ($recorded).")" || rc=$?
if [ "$rc" -eq 3 ]; then
  other="$(claims_table | awk -F'\t' -v n="$node" '$9 == "open" && $2 == "verify" && $4 == n { print $3; exit }')"
  if [ -n "$other" ]; then info "$other started verifying $node at the same time"; exit 4; fi
  claim="$("$SCRIPTS_DIR/claim.sh" new --kind verify --node "$node" \
    --description "Re-run the fixed score on node $node to check its recorded score ($recorded).")"
elif [ "$rc" -ne 0 ]; then
  die "could not claim the verification"
fi

wt="$("$SCRIPTS_DIR/checkout.sh" "$node")"
vstatus=ok
score="$("$SCRIPTS_DIR/evaluate.sh" "$wt" | tail -n 1)" || true
if [ "$score" = failed ] || [ -z "$score" ]; then vstatus=failed; score=""; fi
score_runs="$(cut -f6 "$WORK_DIR/eval/$(git -C "$wt" rev-parse 'HEAD^{tree}').result" 2>/dev/null || true)"

msg="$(mktemp "${TMPDIR:-/tmp}/mycelium_msg.XXXXXX")"
{
  echo "verify $node: ${score:-failed} (recorded $recorded)"
  echo
  echo "Mycelium-Run: $RUN_ID"
  echo "Mycelium-Node: $node"
  echo "Mycelium-Agent-Id: $AGENT_ID"
  echo "Mycelium-Agent: $AGENT_KIND"
  echo "Mycelium-Model: $MODEL"
  echo "Mycelium-Machine: $MACHINE"
  echo "Mycelium-Seed: $SEED"
  [ -z "$score" ] || echo "Mycelium-Score: $score"
  [ -z "$score_runs" ] || echo "Mycelium-Score-Runs: $score_runs"
  echo "Mycelium-Status: $vstatus"
  echo "Mycelium-Claim: $claim"
} > "$msg"
tgit -c "user.name=mycelium $AGENT_ID" -c "user.email=$AGENT_ID@mycelium.invalid" tag -a -F "$msg" "${tag#refs/tags/}" "$sha"
rm -f "$msg"
if ! tgit push --quiet origin "$tag:$tag"; then
  tgit tag -d "${tag#refs/tags/}" >/dev/null
  "$SCRIPTS_DIR/claim.sh" release "$claim" || true
  die "could not push the verify tag"
fi
"$SCRIPTS_DIR/claim.sh" release "$claim" || warn "could not release $claim"
tgit worktree remove --force "$wt" 2>/dev/null || true

verdict="$(awk -v s="$score" -v r="$recorded" -v n="$(noise_at "$recorded")" 'BEGIN {
  if (s == "") { print "FAILED to reproduce: the node is now suspect"; exit }
  d = s - r; if (d < 0) d = -d
  print (d <= n) ? "reproduced within the noise threshold" : "does NOT match (difference " d " > " n "): the node is now suspect" }')"
info "verified $node: recorded $recorded, reproduced ${score:-failed}: $verdict"
echo "${score:-failed}"
