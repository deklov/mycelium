#!/usr/bin/env bash
# claim.sh: the only supported way to claim work (DESIGN section 8).
#
#   claim.sh new --kind <kind> --node <node_id>[,<node_id>...] --description "<one paragraph>"
#       Post a claim. Prints the claim ID on stdout.
#       Exit 3: other agents posted claims at the same time. They are printed;
#       read them, make sure your idea is still clearly different (or change it),
#       then run the command again.
#   claim.sh renew <claim_id>     push a fresh timestamp for long-running work
#   claim.sh release <claim_id>   remove your claim when the work is finished
#   claim.sh cleanup              remove stale, finished and malformed claims (anyone may)
#
# Kinds: experiment, verify, merge, strategy, or any other snake_case word.
# --node is the starting node (experiment), the node to verify (verify), all
# parents (merge), or "tree" for work about the whole tree (strategy).

source "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd="${1:-}"; [ -n "$cmd" ] || usage 1; shift
case "$cmd" in -h|--help) usage 0 ;; esac

load_run
load_agent

write_claim_file() { # FILE ID KIND NODE CREATED RENEWED DESCRIPTION
  {
    echo "kind: $3"
    echo "claim_id: $2"
    echo "agent_id: $AGENT_ID"
    echo "node: $4"
    echo "created: $5"
    echo "renewed: $6"
    echo "created_utc: $(fmt_epoch "$5" %Y-%m-%dT%H:%M:%SZ)"
    echo "machine: $MACHINE"
    echo "---"
    printf '%s\n' "$7"
  } > "$1"
}

open_ids() { claims_table | awk -F'\t' '$9 == "open" { print $1 }' | sort; }

# update_with_retry DESCRIPTION OP_BUILDER: re-runs OP_BUILDER after every rejected push.
retry_push() { # MESSAGE FUNCTION
  local msg=$1 fn=$2 tries=0 rc
  while :; do
    fetch_branch "$CLAIMS_BRANCH"
    rc=0; "$fn" "$msg" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) return 0 ;;   # nothing to do
      3) tries=$((tries + 1)); [ $tries -lt 8 ] || die "claims branch keeps moving; try again later"
         sleep "$(( (RANDOM % 3) + 1 ))" ;;
      *) die "push to $CLAIMS_BRANCH failed" ;;
    esac
  done
}

case "$cmd" in
  new)
    kind="" node="" desc="" id=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --node) node="$2"; shift 2 ;;
        --description) desc="$2"; shift 2 ;;
        --description-file) desc="$(cat "$2")"; shift 2 ;;
        --id) id="$2"; shift 2 ;;
        *) die "unknown option $1" ;;
      esac
    done
    [ -n "$kind" ] && [ -n "$node" ] && [ -n "$desc" ] || usage 1
    require_id kind "$kind"
    for n in $(printf '%s' "$node" | tr ',' ' '); do [ "$n" = tree ] || require_id node_id "$n"; done
    [ "${#desc}" -ge 20 ] || die "the description must say what you will do (at least a sentence)"
    if [ "$node" != tree ] && [ -e "$TARGET_DIR/.git" ]; then
      fetch_target
      for n in $(printf '%s' "$node" | tr ',' ' '); do
        tgit rev-parse -q --verify "refs/tags/mycelium/$RUN_ID/node/$n" >/dev/null || die "no node $n in run $RUN_ID"
      done
    fi
    [ -n "$id" ] || id="${AGENT_ID}_$(stamp)"
    require_id claim_id "$id"
    t="$(now)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/mycelium_claim.XXXXXX")"
    write_claim_file "$tmp" "$id" "$kind" "$node" "$t" "$t" "$desc"
    fetch_branch "$CLAIMS_BRANCH"
    before="$(open_ids)"
    tries=0
    while :; do
      if branch_exists "$CLAIMS_BRANCH" && mgit cat-file -e "$(branch_ref "$CLAIMS_BRANCH"):claims/$id.md" 2>/dev/null; then
        rm -f "$tmp"; die "claim $id already exists"
      fi
      rc=0
      branch_commit_push "$CLAIMS_BRANCH" "claim $id: $kind from $node ($AGENT_ID)" "add:claims/$id.md=$tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then rm -f "$tmp"; echo "$id"; exit 0; fi
      [ "$rc" -eq 3 ] || { rm -f "$tmp"; die "could not push the claim"; }
      fetch_branch "$CLAIMS_BRANCH"
      after="$(open_ids)"
      new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep . || true)"
      if [ -n "$new" ]; then
        rm -f "$tmp"
        {
          echo "mycelium: your claim was NOT posted: other agents claimed work at the same time:"
          claims_table | awk -F'\t' -v ids=" $(echo $new) " 'index(ids, " " $1 " ") { printf "  %s  %s from %s by %s\n    %s\n", $1, $2, $4, $3, $7 }'
          echo "Read them. If your idea is still clearly different, run the same command again;"
          echo "otherwise choose a different idea or starting node first."
        } >&2
        exit 3
      fi
      tries=$((tries + 1)); [ $tries -lt 8 ] || { rm -f "$tmp"; die "claims branch keeps moving; try again later"; }
    done
    ;;

  renew)
    id="${1:-}"; [ -n "$id" ] || usage 1
    do_renew() {
      local ref f tmp
      ref="$(branch_ref "$CLAIMS_BRANCH")"; f="claims/$id.md"
      branch_exists "$CLAIMS_BRANCH" && mgit cat-file -e "$ref:$f" 2>/dev/null || die "no claim $id"
      mgit show "$ref:$f" | grep -q "^agent_id: $AGENT_ID\$" || die "claim $id belongs to another agent"
      tmp="$(mktemp "${TMPDIR:-/tmp}/mycelium_claim.XXXXXX")"
      mgit show "$ref:$f" | awk -v t="$(now)" 'BEGIN { b = 0 } /^---/ { b = 1 } !b && /^renewed:/ { print "renewed: " t; next } { print }' > "$tmp"
      local rc=0; branch_commit_push "$CLAIMS_BRANCH" "$1" "add:$f=$tmp" || rc=$?
      rm -f "$tmp"; return $rc
    }
    retry_push "renew $id ($AGENT_ID)" do_renew
    info "renewed $id"
    ;;

  release)
    id="${1:-}"; [ -n "$id" ] || usage 1
    do_release() {
      local ref; ref="$(branch_ref "$CLAIMS_BRANCH")"
      branch_exists "$CLAIMS_BRANCH" && mgit cat-file -e "$ref:claims/$id.md" 2>/dev/null || return 2
      branch_commit_push "$CLAIMS_BRANCH" "$1" "rm:claims/$id.md"
    }
    retry_push "release $id ($AGENT_ID)" do_release
    info "released $id"
    ;;

  cleanup)
    do_cleanup() {
      local ids ops=() i
      ids="$(claims_table | awk -F'\t' '$9 != "open" { print $1 }')"
      [ -n "$ids" ] || return 2
      for i in $ids; do ops+=("rm:claims/$i.md"); done
      branch_commit_push "$CLAIMS_BRANCH" "$1" "${ops[@]}"
    }
    fetch_target
    retry_push "cleanup stale/finished claims ($AGENT_ID)" do_cleanup
    info "cleanup done"
    ;;

  *) usage 1 ;;
esac
