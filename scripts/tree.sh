#!/usr/bin/env bash
# tree.sh: read the experiment tree of the current run.
#
#   tree.sh best [N]           top N verified nodes, then the best unverified candidates
#   tree.sh frontier [N]       ranked candidate nodes (default 30) with trust, children, open claims
#   tree.sh show <node_id>     full description, ancestry, children, verifications, diffstat
#   tree.sh children <node_id> the children of a node, with their summaries
#   tree.sh claims [--all]     open claims (--all: also stale, done and malformed ones)
#   tree.sh status             live status: who is doing what, recent results, best, notes
#   tree.sh stats              totals by agent and model, and the compounding metric
#   tree.sh notes              strategy notes and the notes board
#   tree.sh invalid            nodes and verify tags that readers ignore, with the reason
#   tree.sh dupes              sibling nodes with identical diffs
#   tree.sh tsv                the full ranked table as TSV (for scripts)
#
# Options (before the command): --no-fetch   use local state only
#
# Every view is recomputed from Git refs; nothing is stored.

source "$(dirname "$0")/lib/common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) export MYCELIUM_NO_FETCH=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
cmd="${1:-status}"; shift || true

load_run
require_target

TAB="$(printf '\t')"
TABLE=""
SORT_DIR=""; [ "$DIRECTION" = higher ] && SORT_DIR="r"

refresh() {
  fetch_target
  fetch_branch "$CLAIMS_BRANCH"
  fetch_branch "$NOTES_BRANCH"
  TABLE="$(ranked_table)"
}

table() { [ -z "$TABLE" ] || printf '%s\n' "$TABLE"; }

# rows with an effective score, sorted best first; $1 = awk filter on trust ($15)
ranked() {
  table | awk -F'\t' -v OFS='\t' "\$16 != \"\" && ($1)" | sort -t "$TAB" -k16,16g${SORT_DIR}
}

trunc() { awk -v w="$1" '{ if (length($0) > w) print substr($0, 1, w - 1) "…"; else print }'; }

print_nodes() { # rows on stdin
  awk -F'\t' '
    BEGIN { printf "  %-28s %10s %10s  %-16s %3s %4s  %s\n", "node", "score", "effective", "trust", "ver", "kids", "summary" }
    { s = $14; if (length(s) > 60) s = substr(s, 1, 59) "…"
      printf "  %-28s %10s %10s  %-16s %3s %4s  %s\n", $1, ($4 == "" ? "-" : $4), ($16 == "" ? "-" : $16), $15, $17, $18, s }'
}

open_claims() { claims_table | awk -F'\t' '$9 == "open"'; }

case "$cmd" in
  best)
    n="${1:-5}"
    refresh
    echo "Run $RUN_ID: best nodes ($DIRECTION is better, noise threshold $NOISE$([ "$NOISE_MODE" = relative ] && echo " relative"))"
    echo
    echo "Verified (reproduced by another agent):"
    v="$(ranked '$15 == "verified"' | head -n "$n")"
    if [ -n "$v" ]; then printf '%s\n' "$v" | print_nodes; else echo "  (none yet)"; fi
    echo
    echo "Unverified candidates (not reported as best until verified):"
    u="$(ranked '$15 == "unverified" || $15 == "inherits_suspect"' | head -n "$n")"
    if [ -n "$u" ]; then printf '%s\n' "$u" | print_nodes; else echo "  (none)"; fi
    s="$(ranked '$15 == "suspect"' | head -n "$n")"
    if [ -n "$s" ]; then echo; echo "Suspect (ranked by reproduced score):"; printf '%s\n' "$s" | print_nodes; fi
    ;;

  frontier)
    n="${1:-30}"
    refresh
    oc="$(open_claims | cut -f4 | tr ' ' '\n' | sort | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ')"
    echo "Run $RUN_ID: frontier ($DIRECTION is better). 'claims' = open claims starting from the node."
    ranked '$15 != "invalid" && $15 != "failed"' | head -n "$n" | awk -F'\t' -v oc="$oc" '
      BEGIN { k = split(oc, a, " "); for (i = 1; i <= k; i++) { split(a[i], kv, "="); c[kv[1]] = kv[2] }
              printf "  %-28s %10s  %-16s %4s %6s  %s\n", "node", "effective", "trust", "kids", "claims", "summary" }
      { s = $14; if (length(s) > 60) s = substr(s, 1, 59) "…"
        printf "  %-28s %10s  %-16s %4s %6s  %s\n", $1, $16, $15, $18, c[$1] + 0, s }'
    nf="$(table | awk -F'\t' '$15 == "failed"' | wc -l | tr -d ' ')"
    echo "  ($nf failed nodes not shown; see 'tree.sh children <node>' to read them)"
    ;;

  show)
    id="${1:-}"; [ -n "$id" ] || die "usage: tree.sh show <node_id>"
    refresh
    row="$(table | awk -F'\t' -v id="$id" '$1 == id')"
    [ -n "$row" ] || die "no node $id in run $RUN_ID"
    sha="$(printf '%s' "$row" | cut -f2)"
    printf '%s\n' "$row" | awk -F'\t' '{
      printf "node %s  (commit %s)\n", $1, substr($2, 1, 12)
      printf "score %s  status %s  trust %s  effective %s\n", ($4 == "" ? "-" : $4), $5, $15, ($16 == "" ? "-" : $16)
      printf "agent %s (%s, %s) on %s  claim %s\n", $6, $7, $8, $9, ($10 == "" ? "-" : $10)
      if ($19 != "") printf "reproductions: %s\n", $19
      if ($13 != "") printf "PROBLEM: %s\n", $13 }'
    echo
    tgit log -1 --format=%B "$sha" | sed '/^Mycelium-[A-Za-z-]*:/d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
    echo
    echo "Ancestry (first parent):"
    cur="$id"; depth=0
    while [ -n "$cur" ] && [ $depth -lt 200 ]; do
      r="$(table | awk -F'\t' -v id="$cur" '$1 == id')"
      [ -n "$r" ] || { echo "  $cur (missing)"; break; }
      printf '%s\n' "$r" | awk -F'\t' '{ s = $14; if (length(s) > 60) s = substr(s, 1, 59) "…"; printf "  %-28s %10s  %-16s %s\n", $1, ($16 == "" ? "-" : $16), $15, s }'
      cur="$(printf '%s' "$r" | cut -f3 | cut -d, -f1)"; depth=$((depth + 1))
    done
    echo
    echo "Children:"
    c="$(table | awk -F'\t' -v id="$id" '{ n = split($3, p, ","); for (i = 1; i <= n; i++) if (p[i] == id) { print; break } }')"
    if [ -n "$c" ]; then printf '%s\n' "$c" | print_nodes; else echo "  (none)"; fi
    parent_sha="$(tgit rev-parse -q --verify "$sha^1" 2>/dev/null || true)"
    if [ -n "$parent_sha" ] && [ "$id" != root ]; then
      echo; echo "Diffstat against first parent:"; tgit diff --stat "$parent_sha" "$sha" | sed 's/^/  /'
    fi
    ;;

  children)
    id="${1:-}"; [ -n "$id" ] || die "usage: tree.sh children <node_id>"
    refresh
    table | awk -F'\t' -v id="$id" '{ n = split($3, p, ","); for (i = 1; i <= n; i++) if (p[i] == id) { print; break } }' \
      | while IFS= read -r r; do
          printf '%s\n' "$r" | awk -F'\t' '{ printf "%s  score %s  %s  trust %s  by %s\n  %s\n", $1, ($4 == "" ? "-" : $4), $5, $15, $6, $14 }'
          tgit log -1 --format=%b "$(printf '%s' "$r" | cut -f2)" | sed '/^Mycelium-[A-Za-z-]*:/d;/^$/d' | sed 's/^/    /'
          echo
        done
    ;;

  claims)
    refresh
    filter='$9 == "open"'; [ "${1:-}" = --all ] && filter='1'
    rows="$(claims_table | awk -F'\t' "$filter")"
    if [ -z "$rows" ]; then echo "No ${1:+matching }open claims in run $RUN_ID."; exit 0; fi
    printf '%s\n' "$rows" | awk -F'\t' '
      BEGIN { printf "  %-34s %-10s %-14s %-24s %5s %-9s  %s\n", "claim", "kind", "agent", "node", "age", "state", "description" }
      { d = $7; if (length(d) > 70) d = substr(d, 1, 69) "…"; if ($8 != "") d = "MALFORMED: " $8
        a = $10; age = (a < 120 ? a "s" : (a < 7200 ? int(a / 60) "m" : int(a / 3600) "h"))
        printf "  %-34s %-10s %-14s %-24s %5s %-9s  %s\n", $1, $2, $3, $4, age, $9, d }'
    ;;

  status)
    refresh
    t_now="$(now)"
    echo "=== Mycelium run $RUN_ID: status ($(iso_now)) ==="
    table | awk -F'\t' '
      { n++; t[$15]++; if ($5 == "improved") imp++ }
      END { printf "Nodes: %d total, %d improved, %d failed, %d verified, %d suspect, %d invalid\n", n, imp, t["failed"], t["verified"], t["suspect"], t["invalid"] }'
    echo
    echo "Active work (open claims):"
    oc="$(open_claims)"
    if [ -n "$oc" ]; then
      printf '%s\n' "$oc" | awk -F'\t' '{ a = $10; age = (a < 120 ? a "s" : (a < 7200 ? int(a / 60) "m" : int(a / 3600) "h"))
        d = $7; if (length(d) > 80) d = substr(d, 1, 79) "…"
        printf "  %-14s %-10s from %-24s %5s ago  %s\n", $3, $2, $4, age, d }'
    else echo "  (nobody is working on anything right now)"; fi
    st="$(claims_table | awk -F'\t' '$9 == "stale"')"
    if [ -n "$st" ]; then
      echo; echo "Possibly dead agents (stale claims, not renewed in time):"
      printf '%s\n' "$st" | awk -F'\t' -v now="$t_now" '{ a = now - $6; printf "  %-14s %-10s %s  last renewed %dm ago\n", $3, $2, $1, int(a / 60) }'
    fi
    echo
    echo "Recent results:"
    table | sort -t "$TAB" -k11,11nr | head -n 8 | awk -F'\t' '{ s = $14; if (length(s) > 60) s = substr(s, 1, 59) "…"
      printf "  %-28s %-14s %10s  %-14s %s\n", $1, $6, ($4 == "" ? "-" : $4), $5, s }'
    echo
    echo "Best:"
    b="$(ranked '$15 == "verified"' | head -n 3)"
    if [ -n "$b" ]; then printf '%s\n' "$b" | awk -F'\t' '{ printf "  verified    %-28s %10s  %s\n", $1, $16, $14 }'
    else echo "  (no verified node yet)"; fi
    u="$(ranked '$15 == "unverified" || $15 == "inherits_suspect"' | head -n 1)"
    [ -z "$u" ] || printf '%s\n' "$u" | awk -F'\t' '{ printf "  candidate   %-28s %10s  %s (%s)\n", $1, $16, $14, $15 }'
    s="$(ranked '$15 == "suspect"')"
    [ -z "$s" ] || printf '%s\n' "$s" | awk -F'\t' '{ printf "  SUSPECT     %-28s recorded %s, reproduced %s\n", $1, $4, $19 }'
    echo
    echo "Strategy notes:"
    if branch_exists "$NOTES_BRANCH" && mgit cat-file -e "$(branch_ref "$NOTES_BRANCH"):strategy.md" 2>/dev/null; then
      sm="$(mgit show "$(branch_ref "$NOTES_BRANCH"):strategy.md")"
      at="$(printf '%s\n' "$sm" | awk -F': *' '/^nodes_at_writing:/ { print $2; exit }')"
      printf '%s\n' "$sm" | sed '/^nodes_at_writing:/d' | head -n 15 | sed 's/^/  /'
      total="$(table | grep -c . || true)"
      every="$(cfg strategy_every 20)"
      if [ -n "$at" ] && [ $((total - at)) -ge "$every" ]; then echo "  -> strategy update due ($((total - at)) nodes since it was written)"; fi
    else
      total="$(table | grep -c . || true)"
      echo "  (none yet)"
      if [ "$total" -ge "$(cfg strategy_every 20)" ]; then echo "  -> strategy update due ($total nodes)"; fi
    fi
    if branch_exists "$NOTES_BRANCH"; then
      nb="$(mgit ls-tree --name-only "$(branch_ref "$NOTES_BRANCH")" board/ 2>/dev/null | grep -c . || true)"
      echo "  Notes board: $nb notes ('tree.sh notes' to read)"
    fi
    ;;

  stats)
    refresh
    echo "Run $RUN_ID: statistics"
    table | awk -F'\t' -v dir="$DIRECTION" '
      function better(a, b) { return dir == "higher" ? a > b : a < b }
      { k = $7 " / " $8; n[k]++; tot++
        if ($5 == "improved") imp[k]++
        if ($15 == "failed") fl[k]++
        if ($15 == "invalid") inv[k]++
        if ($16 != "" && ($15 == "verified")) { if (!(k in best) || better($16 + 0, best[k] + 0)) best[k] = $16 }
        if ($1 != "root" && $15 != "invalid") { nonroot++; if ($18 > 0) built++ } }
      END {
        printf "  %-40s %6s %9s %7s %8s %12s\n", "agent / model", "nodes", "improved", "failed", "invalid", "best (ver.)"
        for (k in n) printf "  %-40s %6d %9d %7d %8d %12s\n", k, n[k], imp[k], fl[k], inv[k], (k in best ? best[k] : "-")
        printf "  %-40s %6d\n", "total", tot
        if (nonroot > 0) printf "\nCompounding: %d of %d non-root nodes (%.0f%%) were later built on.\n", built, nonroot, 100 * built / nonroot
      }'
    ;;

  notes)
    refresh
    if ! branch_exists "$NOTES_BRANCH"; then echo "No notes yet in run $RUN_ID."; exit 0; fi
    ref="$(branch_ref "$NOTES_BRANCH")"
    if mgit cat-file -e "$ref:strategy.md" 2>/dev/null; then echo "=== strategy.md ==="; mgit show "$ref:strategy.md"; echo; fi
    echo "=== notes board ==="
    mgit ls-tree --name-only "$ref" board/ 2>/dev/null | sort | while IFS= read -r f; do
      echo "--- $f"; mgit show "$ref:$f"; echo
    done
    ;;

  invalid)
    refresh
    table | awk -F'\t' '$15 == "invalid" { printf "node   %-28s %s\n", $1, $13 }'
    verify_table | awk -F'\t' '$6 != "" { printf "verify %-28s by %s: %s\n", $1, $2, $6 }'
    claims_table | awk -F'\t' '$9 == "malformed" { printf "claim  %-28s %s\n", $1, $8 }'
    ;;

  dupes)
    refresh
    table | awk -F'\t' '$15 != "invalid" && $1 != "root" && $12 !~ /,/ { print $1 "\t" $3 "\t" $2 "\t" $12 }' \
      | while IFS="$TAB" read -r id parent sha psha; do
          pid="$(tgit diff "$psha" "$sha" | git patch-id --stable | cut -d' ' -f1)"
          [ -n "$pid" ] && printf '%s\t%s\t%s\n' "$parent" "$pid" "$id"
        done | sort | awk -F'\t' '
          { k = $1 "\t" $2; ids[k] = (k in ids ? ids[k] ", " : "") $3; c[k]++ }
          END { for (k in c) if (c[k] > 1) { split(k, p, "\t"); printf "identical diffs from %s: %s\n", p[1], ids[k]; found = 1 }
                if (!found) print "No identical sibling diffs." }'
    ;;

  tsv)
    refresh
    table
    ;;

  *) die "unknown command '$cmd' (try: tree.sh --help)" ;;
esac
