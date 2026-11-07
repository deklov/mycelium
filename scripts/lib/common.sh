# shellcheck shell=bash
# Shared helpers for the Mycelium scripts. Source this file; do not run it.
#
# Portable bash (3.2+), Git (2.30+) and standard Unix tools only.

set -euo pipefail

MYCELIUM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$MYCELIUM_ROOT/scripts"
CONFIG="${MYCELIUM_CONFIG:-$MYCELIUM_ROOT/task/config.yaml}"
TARGET_DIR="${MYCELIUM_TARGET_DIR:-$MYCELIUM_ROOT/target}"
WORK_DIR="${MYCELIUM_WORK_DIR:-$MYCELIUM_ROOT/.work}"
ZERO_SHA=0000000000000000000000000000000000000000

die()  { echo "mycelium: error: $*" >&2; exit 1; }
warn() { echo "mycelium: warning: $*" >&2; }
info() { echo "mycelium: $*" >&2; }

# ---------------------------------------------------------------- config

# cfg KEY [DEFAULT]: read a flat `key: value` line from config.yaml.
cfg() {
  local v=""
  if [ -f "$CONFIG" ]; then
    v=$(awk -v k="$1" '
      index($0, k ":") == 1 {
        s = substr($0, length(k) + 2)
        sub(/^[ \t]+/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
        gsub(/^["\047]|["\047]$/, "", s)
        print s; exit
      }' "$CONFIG")
  fi
  if [ -z "$v" ]; then v="${2-}"; fi
  printf '%s' "$v"
}

# cfg_list KEY: print the items of a YAML list (`key:` followed by `  - item` lines).
cfg_list() {
  [ -f "$CONFIG" ] || return 0
  awk -v k="$1" '
    index($0, k ":") == 1 { on = 1; next }
    on && /^[ \t]*-/ {
      s = $0; sub(/^[ \t]*-[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
      gsub(/^["\047]|["\047]$/, "", s)
      if (s != "") print s
      next
    }
    on && /^[ \t]*(#.*)?$/ { next }
    on { exit }' "$CONFIG"
}

# ---------------------------------------------------------------- identifiers

valid_id() { printf '%s' "$1" | grep -Eq '^[a-z0-9_]+$'; }
sanitize_id() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g'; }
require_id() { valid_id "$2" || die "$1 '$2' is not snake_case ([a-z0-9_]+)"; }

now() { if [ -n "${MYCELIUM_NOW:-}" ]; then echo "$MYCELIUM_NOW"; else date -u +%s; fi; }

# fmt_epoch EPOCH FORMAT (GNU date or BSD date)
fmt_epoch() { date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2"; }
stamp() { fmt_epoch "$(now)" %Y%m%d_%H%M%S; }
iso_now() { fmt_epoch "$(now)" %Y-%m-%dT%H:%M:%SZ; }

# human_age SECONDS -> 42s / 7m / 3h / 2d
human_age() {
  local s=$1
  if [ "$s" -lt 0 ]; then s=0; fi
  if [ "$s" -lt 120 ]; then echo "${s}s"
  elif [ "$s" -lt 7200 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}

# ---------------------------------------------------------------- run identity

load_run() {
  RUN_ID="${MYCELIUM_RUN_ID:-$(cfg run_id)}"
  [ -n "$RUN_ID" ] || die "no run_id: set run_id in task/config.yaml (or MYCELIUM_RUN_ID)"
  require_id run_id "$RUN_ID"
  DIRECTION="$(cfg direction higher)"
  case "$DIRECTION" in higher|lower) ;; *) die "direction must be 'higher' or 'lower'";; esac
  NOISE="$(cfg noise_threshold 0)"
  NOISE_MODE="$(cfg noise_mode absolute)"
  case "$NOISE_MODE" in absolute|relative) ;; *) die "noise_mode must be 'absolute' or 'relative'";; esac
  EVAL_BUDGET="$(cfg eval_budget_seconds 600)"
  SEED="$(cfg seed 0)"
  DATA_VERSION="$(cfg data_version '')"
  CLAIMS_BRANCH="mycelium/$RUN_ID/claims"
  NOTES_BRANCH="mycelium/$RUN_ID/notes"
  READY_TAG="mycelium/$RUN_ID/ready"
  NODE_PREFIX="refs/tags/mycelium/$RUN_ID/node/"
  VERIFY_PREFIX="refs/tags/mycelium/$RUN_ID/verify/"
}

load_agent() {
  MACHINE="${MYCELIUM_MACHINE:-$(sanitize_id "$(hostname -s 2>/dev/null || hostname)")}"
  AGENT_ID="${MYCELIUM_AGENT_ID:-${MACHINE}_manual}"
  require_id agent_id "$AGENT_ID"
  AGENT_KIND="${MYCELIUM_AGENT:-}"
  if [ -z "$AGENT_KIND" ]; then
    if [ -n "${CLAUDECODE:-}" ]; then AGENT_KIND=claude_code
    elif [ -n "${CODEX_SANDBOX:-}${CODEX_HOME:-}" ]; then AGENT_KIND=codex
    else AGENT_KIND=unknown; fi
  fi
  MODEL="${MYCELIUM_MODEL:-unknown}"
}

# claim_timeout KIND -> seconds
claim_timeout() {
  local t
  t="$(cfg "claim_timeout_${1}_seconds" '')"
  [ -n "$t" ] || t="$(cfg claim_timeout_seconds '')"
  [ -n "$t" ] || t=$((3 * ${EVAL_BUDGET:-600}))
  echo "$t"
}

# noise_at REFERENCE_SCORE -> the noise threshold that applies around that score
# (noise_threshold itself, or noise_threshold x |score| when noise_mode is relative).
noise_at() {
  awk -v n="$NOISE" -v m="$NOISE_MODE" -v r="${1:-0}" 'BEGIN { if (r < 0) r = -r; printf "%.6g\n", (m == "relative") ? n * r : n }'
}

# ---------------------------------------------------------------- git helpers

tgit() { git -C "$TARGET_DIR" "$@"; }
mgit() { git -C "$MYCELIUM_ROOT" "$@"; }

require_target() {
  [ -e "$TARGET_DIR/.git" ] || die "no target checkout at $TARGET_DIR (run onboarding, or: git submodule update --init)"
}

# Fetch this run's node and verify tags from the target remote.
fetch_target() {
  [ -z "${MYCELIUM_NO_FETCH:-}" ] || return 0
  tgit fetch --quiet --no-tags origin "+refs/tags/mycelium/$RUN_ID/*:refs/tags/mycelium/$RUN_ID/*" \
    || warn "could not fetch tags from the target remote; using local state"
}

# fetch_branch BRANCH: refresh refs/remotes/origin/BRANCH in the Mycelium repo.
fetch_branch() {
  [ -z "${MYCELIUM_NO_FETCH:-}" ] || return 0
  local b=$1 rc=0
  if mgit fetch --quiet --no-tags origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null; then
    return 0
  fi
  mgit ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    mgit update-ref -d "refs/remotes/origin/$b" 2>/dev/null || true   # branch does not exist yet
  else
    warn "could not fetch $b; using local state"
  fi
}

branch_ref() { echo "refs/remotes/origin/$1"; }
branch_exists() { mgit rev-parse -q --verify "$(branch_ref "$1")^{commit}" >/dev/null; }

# branch_commit_push BRANCH MESSAGE OP...
#   OP is "add:<path>=<local file>" or "rm:<path>".
# Builds a commit on top of origin/BRANCH with a private index (no checkout
# needed) and pushes it. Returns 0 on success, 3 if the push was rejected
# because the branch moved (fetch and retry), 1 on any other failure.
branch_commit_push() {
  local branch=$1 msg=$2; shift 2
  local ref idx tree commit out rc op path file blob
  ref="$(branch_ref "$branch")"
  idx="$(mktemp "${TMPDIR:-/tmp}/mycelium_idx.XXXXXX")"
  rm -f "$idx"
  local parent_args=()
  if branch_exists "$branch"; then
    GIT_INDEX_FILE="$idx" mgit read-tree "$ref"
    parent_args=(-p "$ref")
  else
    GIT_INDEX_FILE="$idx" mgit read-tree --empty
  fi
  for op in "$@"; do
    case "$op" in
      add:*)
        path="${op#add:}"; file="${path#*=}"; path="${path%%=*}"
        blob="$(mgit hash-object -w "$file")"
        GIT_INDEX_FILE="$idx" mgit update-index --add --cacheinfo "100644,$blob,$path" ;;
      rm:*)
        GIT_INDEX_FILE="$idx" mgit update-index --force-remove "${op#rm:}" ;;
      *) rm -f "$idx"; die "bad op $op" ;;
    esac
  done
  tree="$(GIT_INDEX_FILE="$idx" mgit write-tree)"
  rm -f "$idx"
  commit="$(mgit commit-tree "$tree" ${parent_args[@]+"${parent_args[@]}"} -m "$msg")"
  if [ -n "${MYCELIUM_TEST_BEFORE_PUSH:-}" ]; then
    eval "$MYCELIUM_TEST_BEFORE_PUSH"
  fi
  rc=0
  out="$(mgit push --porcelain origin "$commit:refs/heads/$branch" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    mgit update-ref "$ref" "$commit"
    return 0
  fi
  if printf '%s' "$out" | grep -q '\[rejected\]'; then return 3; fi
  printf '%s\n' "$out" >&2
  return 1
}

# ---------------------------------------------------------------- tree data

# node_table: one TSV line per node tag of this run (from local refs; call
# fetch_target first). Columns:
#   1 node_id  2 sha  3 parents(node ids, comma)  4 score  5 status
#   6 agent_id 7 agent 8 model 9 machine 10 claim 11 commit_time
#   12 git_parents(shas, comma) 13 problem 14 summary
node_table() {
  local tags
  tags="$(tgit for-each-ref "$NODE_PREFIX" --format='%(refname:lstrip=5)%09%(objectname)%09%(*objectname)' 2>/dev/null || true)"
  [ -n "$tags" ] || return 0
  local fmt='%H%x1f%P%x1f%(trailers:key=Mycelium-Run,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Node,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Parent,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Score,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Status,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Agent-Id,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Agent,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Model,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Machine,valueonly,separator=%x2c)%x1f%(trailers:key=Mycelium-Claim,valueonly,separator=%x2c)%x1f%ct%x1f%s%x1e'
  local commits
  commits="$(printf '%s\n' "$tags" | awk -F'\t' '{ print ($3 != "" ? $3 : $2) }' | sort -u \
    | tgit log --no-walk=unsorted --stdin --format="$fmt" 2>/dev/null || true)"
  local protected
  protected="$(protected_report "$tags")"
  awk -v run="$RUN_ID" -v tagsdata="$tags" -v commitsdata="$commits" -v protdata="$protected" '
    function isnum(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ || x ~ /^-?\.[0-9]+$/ }
    BEGIN {
      FS = "\t"
      nc = split(commitsdata, recs, "\036")
      for (i = 1; i <= nc; i++) {
        r = recs[i]; sub(/^\n+/, "", r)
        if (r == "") continue
        n = split(r, f, "\037")
        sha = f[1]; c_par[sha] = f[2]; c_run[sha] = f[3]; c_node[sha] = f[4]; c_parent[sha] = f[5]
        c_score[sha] = f[6]; c_status[sha] = f[7]; c_aid[sha] = f[8]; c_agent[sha] = f[9]
        c_model[sha] = f[10]; c_machine[sha] = f[11]; c_claim[sha] = f[12]; c_time[sha] = f[13]
        s = f[14]; gsub(/\t/, " ", s); c_subj[sha] = s
      }
      np = split(protdata, pl, "\n")
      for (i = 1; i <= np; i++) { if (pl[i] == "") continue; split(pl[i], pf, "\t"); prot[pf[1]] = pf[2] }
      nt = split(tagsdata, tl, "\n")
      for (i = 1; i <= nt; i++) {
        if (tl[i] == "") continue
        split(tl[i], tf, "\t")
        id = tf[1]; sha = (tf[3] != "" ? tf[3] : tf[2])
        ids[++count] = id; node_sha[id] = sha; sha_node[sha] = id
      }
      for (k = 1; k <= count; k++) {
        id = ids[k]; sha = node_sha[id]; p = ""
        gp = c_par[sha]; gsub(/ /, ",", gp)
        if (!(sha in c_time)) p = "tag does not point at a commit"
        else if (id !~ /^[a-z0-9_]+$/) p = "node id is not snake_case"
        else if (c_run[sha] != run) p = "Mycelium-Run is \"" c_run[sha] "\", expected " run
        else if (c_node[sha] != id) p = "Mycelium-Node is \"" c_node[sha] "\", expected " id
        else if (c_aid[sha] == "") p = "missing Mycelium-Agent-Id"
        else if (c_status[sha] !~ /^(baseline|improved|no_improvement|failed)$/) p = "bad Mycelium-Status \"" c_status[sha] "\""
        else if (c_status[sha] != "failed" && !isnum(c_score[sha])) p = "missing or non-numeric Mycelium-Score"
        else if (id == "root" && c_parent[sha] != "") p = "root must not have Mycelium-Parent"
        else if (id != "root" && c_parent[sha] == "") p = "missing Mycelium-Parent"
        else if (id != "root") {
          np2 = split(c_parent[sha], pp, ","); ng = split(c_par[sha], gg, " ")
          if (np2 != ng) p = "Mycelium-Parent does not match the Git parents"
          for (j = 1; j <= np2 && p == ""; j++) {
            if (!(pp[j] in node_sha)) p = "parent " pp[j] " is not a node"
            else if (node_sha[pp[j]] != gg[j]) p = "Mycelium-Parent does not match the Git parents"
          }
          if (p == "" && (sha in prot) && prot[sha] != "ok") p = "touches protected path " prot[sha]
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, sha, c_parent[sha], c_score[sha], c_status[sha], c_aid[sha], c_agent[sha], c_model[sha], c_machine[sha], c_claim[sha], c_time[sha], gp, p, c_subj[sha]
      }
    }'
}

# Protected paths (DESIGN 10.1) are shell patterns from config.yaml in which
# `*` also matches `/`: `bench/*` covers everything under bench/.
# protected_filter: read paths on stdin, print those that are protected.
protected_filter() {
  local globs path g
  globs="$(cfg_list protected_paths)"
  [ -n "$globs" ] || { cat >/dev/null; return 0; }
  while IFS= read -r path; do
    while IFS= read -r g; do
      # shellcheck disable=SC2053
      if [ -n "$g" ] && [[ "$path" == $g ]]; then printf '%s\n' "$path"; break; fi
    done <<EOF
$globs
EOF
  done
}

# protected_paths_changed BASE TREEISH -> prints the first protected path changed, if any.
protected_paths_changed() {
  tgit diff --name-only --no-renames "$1" "$2" 2>/dev/null | protected_filter | head -n 1
}

# protected_report TAGS: "sha<TAB>ok|<path>" for every non-root node, cached per sha.
protected_report() {
  local tags=$1 globs root_sha cache key line sha bad
  globs="$(cfg_list protected_paths)"
  [ -n "$globs" ] || return 0
  root_sha="$(printf '%s\n' "$tags" | awk -F'\t' '$1 == "root" { print ($3 != "" ? $3 : $2) }')"
  [ -n "$root_sha" ] || return 0
  key="$(printf '%s\n%s' "$root_sha" "$globs" | git hash-object --stdin)"
  mkdir -p "$WORK_DIR/cache"
  cache="$WORK_DIR/cache/protected_${RUN_ID}_${key}"
  touch "$cache"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="$(printf '%s' "$line" | awk -F'\t' '{ print ($3 != "" ? $3 : $2) }')"
    [ "$sha" != "$root_sha" ] || continue
    if ! grep -q "^$sha	" "$cache"; then
      bad="$(protected_paths_changed "$root_sha" "$sha")"
      printf '%s\t%s\n' "$sha" "${bad:-ok}" >> "$cache"
    fi
  done <<EOF
$tags
EOF
  cat "$cache"
}

# verify_table: one TSV line per verify tag. Columns:
#   1 node_id 2 verifier_agent_id 3 score 4 status 5 claim 6 problem 7 tagger_epoch
verify_table() {
  local fmt='%(refname:lstrip=5)%1f%(objecttype)%1f%(*objectname)%1f%(contents:trailers:key=Mycelium-Run,valueonly,separator=%x2c)%1f%(contents:trailers:key=Mycelium-Node,valueonly,separator=%x2c)%1f%(contents:trailers:key=Mycelium-Agent-Id,valueonly,separator=%x2c)%1f%(contents:trailers:key=Mycelium-Score,valueonly,separator=%x2c)%1f%(contents:trailers:key=Mycelium-Status,valueonly,separator=%x2c)%1f%(contents:trailers:key=Mycelium-Claim,valueonly,separator=%x2c)%1f%(taggerdate:unix)%1e'
  local data nodes
  data="$(tgit for-each-ref "$VERIFY_PREFIX" --format="$fmt" 2>/dev/null || true)"
  [ -n "$data" ] || return 0
  nodes="$(tgit for-each-ref "$NODE_PREFIX" --format='%(refname:lstrip=5)%09%(objectname)%09%(*objectname)' 2>/dev/null || true)"
  awk -v run="$RUN_ID" -v data="$data" -v nodes="$nodes" '
    function isnum(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ || x ~ /^-?\.[0-9]+$/ }
    BEGIN {
      nn = split(nodes, nl, "\n")
      for (i = 1; i <= nn; i++) { if (nl[i] == "") continue; split(nl[i], t, "\t"); nsha[t[1]] = (t[3] != "" ? t[3] : t[2]) }
      n = split(data, recs, "\036")
      for (i = 1; i <= n; i++) {
        r = recs[i]; sub(/^\n+/, "", r); if (r == "") continue
        split(r, f, "\037")
        name = f[1]; node = name; sub(/\/.*/, "", node); ver = name; sub(/^[^\/]*\//, "", ver)
        p = ""
        if (f[2] != "tag") p = "verify tag is not annotated"
        else if (!(node in nsha)) p = "no such node " node
        else if (f[3] != nsha[node]) p = "verify tag does not point at the node commit"
        else if (f[4] != run) p = "wrong Mycelium-Run"
        else if (f[5] != node) p = "Mycelium-Node does not match the tag name"
        else if (f[6] != ver) p = "Mycelium-Agent-Id does not match the tag name"
        else if (f[8] !~ /^(ok|failed)$/) p = "bad Mycelium-Status"
        else if (f[8] == "ok" && !isnum(f[7])) p = "missing or non-numeric Mycelium-Score"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", node, ver, f[7], f[8], f[9], p, f[10]
      }
    }'
}

# ranked_table: node_table joined with verifications and ranking (DESIGN 7.2).
# Columns: node_table columns 1-14, then
#   15 trust 16 effective_score 17 n_verify 18 children 19 verify_scores
ranked_table() {
  local nodes verifs
  nodes="$(node_table)"
  verifs="$(verify_table)"
  [ -n "$nodes" ] || return 0
  awk -v dir="$DIRECTION" -v noise="$NOISE" -v noise_mode="$NOISE_MODE" -v nodes="$nodes" -v verifs="$verifs" -f "$SCRIPTS_DIR/lib/rank.awk"
}

# ---------------------------------------------------------------- claims

# parse_claim CLAIM_ID < FILE -> TSV:
#   claim_id kind agent_id node created renewed description(one line) problem
parse_claim() {
  awk -v fname="$1" '
    BEGIN { body = 0; desc = "" }
    body { line = $0; gsub(/\t/, " ", line); desc = (desc == "" ? line : desc " " line); next }
    /^---[ \t]*$/ { body = 1; next }
    /^[a-z_]+:/ { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[a-z_]+:[ \t]*/, "", v); sub(/[ \t]+$/, "", v); h[k] = v; next }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", desc); gsub(/  +/, " ", desc)
      p = ""
      if (h["claim_id"] == "") p = "missing claim_id"
      else if (h["claim_id"] != fname) p = "claim_id does not match the file name"
      else if (h["claim_id"] !~ /^[a-z0-9_]+$/) p = "claim_id is not snake_case"
      else if (h["kind"] !~ /^[a-z0-9_]+$/) p = "missing or bad kind"
      else if (h["agent_id"] !~ /^[a-z0-9_]+$/) p = "missing or bad agent_id"
      else if (h["node"] == "") p = "missing node"
      else if (h["created"] !~ /^[0-9]+$/) p = "missing or bad created"
      else if (h["renewed"] !~ /^[0-9]+$/) p = "missing or bad renewed"
      else if (desc == "") p = "missing description"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", fname, h["kind"], h["agent_id"], h["node"], h["created"], h["renewed"], desc, p
    }'
}

# claims_raw [REF]: parsed claims on the claims branch (call fetch_branch first).
claims_raw() {
  local ref=${1:-$(branch_ref "$CLAIMS_BRANCH")} f
  mgit rev-parse -q --verify "$ref^{commit}" >/dev/null || return 0
  mgit ls-tree --name-only "$ref" claims/ 2>/dev/null | while IFS= read -r f; do
    case "$f" in claims/*.md) ;; *) continue ;; esac
    mgit show "$ref:$f" 2>/dev/null | parse_claim "$(basename "$f" .md)"
  done
}

# done_claims: claim ids fulfilled by a node or a verify tag.
done_claims() {
  {
    tgit for-each-ref "$NODE_PREFIX" --format='%(*objectname)%(objectname)' 2>/dev/null \
      | cut -c1-40 | tgit log --no-walk --stdin --format='%(trailers:key=Mycelium-Claim,valueonly,separator=%x0a)' 2>/dev/null || true
    tgit for-each-ref "$VERIFY_PREFIX" --format='%(contents:trailers:key=Mycelium-Claim,valueonly,separator=%x0a)' 2>/dev/null || true
  } | grep -E '^[a-z0-9_]+$' | sort -u || true
}

# claims_table: claims with a state column appended:
#   1 claim_id 2 kind 3 agent_id 4 node 5 created 6 renewed 7 description 8 problem 9 state 10 age_seconds
#   state: open | stale | done | malformed
claims_table() {
  local raw done_ids t_now line kind
  raw="$(claims_raw "$@")"
  [ -n "$raw" ] || return 0
  done_ids="$(done_claims | tr '\n' ' ')"
  t_now="$(now)"
  # timeouts per kind
  local kinds kt=""
  kinds="$(printf '%s\n' "$raw" | cut -f2 | sort -u)"
  for kind in $kinds; do
    valid_id "$kind" || continue
    kt="$kt $kind=$(claim_timeout "$kind")"
  done
  printf '%s\n' "$raw" | awk -F'\t' -v OFS='\t' -v done_ids="$done_ids" -v t_now="$t_now" -v kt="$kt" -v deft="$(claim_timeout default)" '
    BEGIN { n = split(done_ids, d, " "); for (i = 1; i <= n; i++) isdone[d[i]] = 1
            n = split(kt, k, " "); for (i = 1; i <= n; i++) { split(k[i], kv, "="); tmo[kv[1]] = kv[2] } }
    {
      t = ($2 in tmo) ? tmo[$2] : deft
      if ($8 != "") st = "malformed"
      else if ($1 in isdone) st = "done"
      else if (t_now - $6 > t) st = "stale"
      else st = "open"
      print $0, st, t_now - $5
    }'
}
