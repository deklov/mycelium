#!/usr/bin/env bash
# note.sh: write to the notes branch, mycelium/<run_id>/notes (DESIGN 16).
#
#   note.sh board --title "<title>" (--text "<text>" | --file <file>)
#       Post a lesson that is not tied to a single node, e.g. "learning rates
#       above X always diverge". One file per note; notes are never edited.
#   note.sh strategy --file <file> [--claim <claim_id>]
#       Replace strategy.md with a new summary of the tree: directions tried,
#       how they did, what is underexplored. Claim it first (kind strategy,
#       node "tree"). Exit 3 if someone else updated it meanwhile: re-read it.
#   note.sh show     same as tree.sh notes

source "$(dirname "$0")/lib/common.sh"

cmd="${1:-}"; shift || true
load_run
load_agent

case "$cmd" in
  board)
    title="" text=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --text) text="$2"; shift 2 ;;
        --file) text="$(cat "$2")"; shift 2 ;;
        *) die "unknown option $1" ;;
      esac
    done
    [ -n "$title" ] && [ -n "$text" ] || die "usage: note.sh board --title T (--text X | --file F)"
    id="${AGENT_ID}_$(stamp)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/mycelium_note.XXXXXX")"
    { echo "# $title"; echo; echo "agent_id: $AGENT_ID"; echo "created_utc: $(iso_now)"; echo; printf '%s\n' "$text"; } > "$tmp"
    tries=0
    while :; do
      fetch_branch "$NOTES_BRANCH"
      rc=0; branch_commit_push "$NOTES_BRANCH" "note $id: $title" "add:board/$id.md=$tmp" || rc=$?
      [ "$rc" -eq 0 ] && break
      [ "$rc" -eq 3 ] && [ $tries -lt 8 ] || { rm -f "$tmp"; die "could not push the note"; }
      tries=$((tries + 1)); sleep 1
    done
    rm -f "$tmp"
    info "posted board/$id.md"
    ;;

  strategy)
    file="" claim=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --file) file="$2"; shift 2 ;;
        --claim) claim="$2"; shift 2 ;;
        *) die "unknown option $1" ;;
      esac
    done
    [ -n "$file" ] && [ -f "$file" ] || die "usage: note.sh strategy --file F [--claim ID]"
    require_target
    fetch_target
    fetch_branch "$NOTES_BRANCH"
    total="$(node_table | grep -c . || true)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/mycelium_note.XXXXXX")"
    { echo "nodes_at_writing: $total"; echo "agent_id: $AGENT_ID"; echo "created_utc: $(iso_now)"; echo; cat "$file"; } > "$tmp"
    rc=0; branch_commit_push "$NOTES_BRANCH" "strategy update by $AGENT_ID at $total nodes" "add:strategy.md=$tmp" || rc=$?
    rm -f "$tmp"
    if [ "$rc" -eq 3 ]; then
      echo "mycelium: strategy.md was updated by someone else meanwhile; read it (tree.sh notes) and try again" >&2
      exit 3
    fi
    [ "$rc" -eq 0 ] || die "could not push strategy.md"
    [ -z "$claim" ] || "$SCRIPTS_DIR/claim.sh" release "$claim" || true
    info "strategy.md updated ($total nodes)"
    ;;

  show) exec "$SCRIPTS_DIR/tree.sh" notes ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
