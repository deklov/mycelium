#!/usr/bin/env bash
# End-to-end test of the Mycelium scripts (DESIGN 17, item 6).
#
# Builds everything in a temp dir: a tiny synthetic target whose score is
# (a + b) * weight, local bare repos standing in for both forks, an onboarding
# clone and two clones simulating two machines. Scripted fake agents then
# exercise claims (including a push race), recording, a failed node, a merge,
# verification, ranking, suspects, protected paths, notes, stale claims, the
# pre-push hook and the headless launch loop.
#
# No network, no LLM, no Git host. Never writes to this repository.
#
#   tests/e2e.sh [--keep]    --keep leaves the temp dir for inspection

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
T="$(mktemp -d "${TMPDIR:-/tmp}/mycelium_e2e.XXXXXX")"
if [ "$KEEP" -eq 0 ]; then trap 'rm -rf "$T"' EXIT; else echo "temp dir: $T"; fi

# allow file:// submodules (disabled by default in recent Git)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid
unset MYCELIUM_RUN_ID MYCELIUM_AGENT_ID MYCELIUM_MODE MYCELIUM_NOW MYCELIUM_TEST_BEFORE_PUSH CLAUDECODE || true
export MYCELIUM_MACHINE=e2e MYCELIUM_AGENT=fake MYCELIUM_MODEL=scripted

PASS=0
ok()   { PASS=$((PASS + 1)); echo "  ok  $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }
has()  { printf '%s' "$1" | grep -q -- "$2" || { printf '%s\n' "$1" >&2; fail "expected '$2'"; }; }
hasnt(){ ! printf '%s' "$1" | grep -q -- "$2" || { printf '%s\n' "$1" >&2; fail "did not expect '$2'"; }; }
q()    { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------------ remotes
echo "== setup"
mkdir -p "$T/remote" "$T/seed_target/bench"
( cd "$T/seed_target"
  git init -q -b main
  echo 10 > a.txt; echo 5 > b.txt; echo 1 > bench/weight.txt
  echo "toy target: score = (a + b) * weight" > README
  git add -A && git commit -q -m "toy baseline"
  git clone -q --bare . "$T/remote/target.git" )

mkdir -p "$T/seed_mycelium"
( cd "$REPO" && { git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*' -not -path './.work/*' | sed 's|^\./||'; } ) \
  | grep -Ev '^(\.work/|target(/|$)|\.gitmodules$)' | (cd "$REPO" && tar -cf - -T -) | tar -xf - -C "$T/seed_mycelium"
( cd "$T/seed_mycelium"
  cat > task/config.yaml <<'EOF'
run_id: e2e_run
direction: higher
noise_threshold: 0.5
eval_budget_seconds: 10
seed: 7
strategy_every: 3
eval_repeats: 3
protected_paths:
  - "bench/*"
EOF
  cat > task/score.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$1"
a="$(cat a.txt)"; b="$(cat b.txt)"; w="$(cat bench/weight.txt)"
case "$a$b" in *crash*) echo "boom" >&2; exit 1 ;; esac
echo "seed $MYCELIUM_SEED" >&2
echo $(( (a + b) * w ))
EOF
  chmod +x task/score.sh
  git init -q -b main && git add -A && git commit -q -m "mycelium template + e2e task"
  git clone -q --bare . "$T/remote/mycelium.git" )
ok "remotes created"

# ------------------------------------------------------------------ onboarding
git clone -q "$T/remote/mycelium.git" "$T/onboard"
cd "$T/onboard"
git submodule add -q "$T/remote/target.git" target
sed -i.bak "s|^target_fork:.*|target_fork: \"$T/remote/target.git\"|" task/config.yaml && rm -f task/config.yaml.bak
grep -q '^target_fork:' task/config.yaml || echo "target_fork: \"$T/remote/target.git\"" >> task/config.yaml
git add -A && git commit -q -m "add target submodule"
git push -q origin main
eval "$(scripts/launch.sh --print-env --allow-unready --agent-id onboard_1)"
unset MYCELIUM_MODE
out="$(scripts/onboard.sh status)"
has "$out" "\[x\] 1. target: exploration fork"; has "$out" "\[ \] 5. baseline scored"
out="$(scripts/onboard.sh noise 3 2>&1)"
has "$out" "mean 15  stddev 0"
rc=0; scripts/onboard.sh ready >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "ready must require a root node"
scripts/onboard.sh root 2>/dev/null
out="$(scripts/onboard.sh status)"
has "$out" "\[x\] 5. root node"
scripts/onboard.sh ready 2>/dev/null
out="$(scripts/onboard.sh status)"
has "$out" "\[x\] 8. run marked ready"
ok "onboarding: submodule, root node, ready tag"

# ------------------------------------------------------------------ two machines
for b in box1 box2; do
  git clone -q --recurse-submodules "$T/remote/mycelium.git" "$T/$b"
done
as() { # as <box> <agent_id> <command...>: run in a box as an exploring agent
  local box=$1 id=$2; shift 2
  ( cd "$T/$box" && eval "$(scripts/launch.sh --print-env --agent-id "$id")" && "$@" )
}
out="$(as box1 box1_1 scripts/tree.sh status)"
has "$out" "Nodes: 1 total"
has "$out" "nobody is working"
ok "status on a fresh run"

out="$(cd "$T/box1" && MYCELIUM_RUN_ID=nope scripts/launch.sh --print-env 2>&1 || true)"
has "$out" "not marked ready"
ok "launch.sh refuses an unready run"

# ------------------------------------------------------------------ claims and the push race
c1="$(as box1 box1_1 scripts/claim.sh new --kind experiment --node root --description "Raise a to 15 to see whether a dominates the score.")"
race="cd $T/box1 && MYCELIUM_TEST_BEFORE_PUSH= MYCELIUM_AGENT_ID=box1_1 scripts/claim.sh new --kind experiment --node root --description 'Lower b to 4 to test a decrease.' --id box1_1_racer >/dev/null"
rc=0; out="$(as box2 box2_1 env MYCELIUM_TEST_BEFORE_PUSH="$race" scripts/claim.sh new --kind experiment --node root --description "Raise b to 8 to see whether b helps." 2>&1)" || rc=$?
[ "$rc" -eq 3 ] || { echo "$out"; fail "racing claim should exit 3 (got $rc)"; }
has "$out" "box1_1_racer"
ok "push race: rejected claim shows the new competing claim (exit 3)"
c2="$(as box2 box2_1 scripts/claim.sh new --kind experiment --node root --description "Raise b to 8 to see whether b helps.")"
out="$(as box1 box1_1 scripts/tree.sh claims)"
has "$out" "$c1"; has "$out" "$c2"; has "$out" "box1_1_racer"
ok "retry succeeds; three open claims visible"

rc=0; out="$(as box1 box1_1 scripts/claim.sh release "$c2" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "deleting another agent's live claim must be blocked"
has "$out" "still live"
ok "pre-push hook blocks deleting someone else's live claim"

# ------------------------------------------------------------------ experiments
experiment() { # experiment <box> <agent> <claim> <file> <value> <summary> <nodes...>
  local box=$1 id=$2 claim=$3 file=$4 val=$5 summary=$6; shift 6
  ( cd "$T/$box" && eval "$(scripts/launch.sh --print-env --agent-id "$id")"
    w="$(scripts/checkout.sh "$@" 2>/dev/null)"
    [ -z "$file" ] || echo "$val" > "$w/$file"
    scripts/evaluate.sh "$w" >/dev/null 2>&1 || true
    scripts/record.sh --worktree "$w" --summary "$summary" --description "Scripted e2e experiment: set $file to $val." ${claim:+--claim "$claim"} 2>/dev/null )
}
n1="$(experiment box1 box1_1 "$c1" a.txt 15 "Raise a to 15" root)"
n2="$(experiment box2 box2_1 "$c2" b.txt 8 "Raise b to 8" root)"
out="$(as box1 box1_1 scripts/tree.sh show "$n1")"
has "$out" "score 20  status improved"
out="$(as box1 box1_1 scripts/tree.sh claims)"
hasnt "$out" "$c1"; hasnt "$out" "$c2"
ok "two improved nodes recorded; their claims released"

nf="$(experiment box2 box2_1 "" a.txt crash "Try a crash" root)"
out="$(as box1 box1_1 scripts/tree.sh show "$nf")"
has "$out" "status failed"; has "$out" "trust failed"
ok "failed experiment is recorded as a failed node"

# build outputs: new binaries are refused, ignore_paths keeps them out
out="$(cd "$T/box1" && eval "$(scripts/launch.sh --print-env --agent-id box1_1)"
  w="$(scripts/checkout.sh "$n1" 2>/dev/null)"; printf 'bin\000ary' > "$w/prog"; echo 16 > "$w/a.txt"
  scripts/evaluate.sh "$w" >/dev/null 2>&1
  scripts/record.sh --worktree "$w" --summary "With a binary" --description "Should be refused." 2>&1 || true
  git -C target worktree remove --force "$w")"
has "$out" "adds binary files"; has "$out" "prog"
ok "record.sh refuses new binary files (build outputs)"

out="$(cd "$T/box1" && eval "$(scripts/launch.sh --print-env --agent-id box1_1)"
  w="$(scripts/checkout.sh "$n1" 2>/dev/null)"; echo 10 > "$w/bench/weight.txt"
  echo "score=$(scripts/evaluate.sh "$w" 2>/dev/null)"
  scripts/record.sh --worktree "$w" --summary "Game the weight" --description "Should be refused." 2>&1 || true)"
has "$out" "score=20"; has "$out" "protected path"
ok "protected path: restored before scoring (20, not 200) and refused by record.sh"

# hand-pushed nodes: one gaming a protected path, one with a fake score
handnode() { # handnode <box> <parent> <node_id> <file> <value> <score>
  ( cd "$T/$1/target"
    git fetch -q origin "+refs/tags/mycelium/e2e_run/*:refs/tags/mycelium/e2e_run/*"
    git checkout -q --detach "mycelium/e2e_run/node/$2"
    echo "$5" > "$4"; git add -A
    git commit -q -m "hand-made $3

Hand-made node for the e2e test.

Mycelium-Run: e2e_run
Mycelium-Node: $3
Mycelium-Parent: $2
Mycelium-Score: $6
Mycelium-Status: improved
Mycelium-Agent-Id: box1_1
Mycelium-Agent: fake
Mycelium-Model: scripted
Mycelium-Machine: e2e"
    git tag "mycelium/e2e_run/node/$3" && git push -q origin "mycelium/e2e_run/node/$3" )
}
handnode box1 "$n1" box1_1_gamed bench/weight.txt 10 200
out="$(as box2 box2_1 scripts/tree.sh invalid)"
has "$out" "box1_1_gamed.*protected path bench/weight.txt"
out="$(as box2 box2_1 scripts/tree.sh best)"
hasnt "$out" "box1_1_gamed"
ok "hand-pushed node touching a protected path is invalid and never ranked"

# merge
cm="$(as box1 box1_1 scripts/claim.sh new --kind merge --node "$n1,$n2" --description "Merge the a and b improvements; they touch different files.")"
nm="$(experiment box1 box1_1 "$cm" "" "" "Merge a=15 and b=8" "$n1" "$n2")"
out="$(cd "$T/box1/target" && git log -1 --format=%B "mycelium/e2e_run/node/$nm")"
has "$out" "Mycelium-Parent: $n1"; has "$out" "Mycelium-Parent: $n2"; has "$out" "Mycelium-Score: 23"
has "$out" "Mycelium-Score-Runs: 23,23,23"
out="$(as box2 box2_1 scripts/tree.sh show "$nm")"
has "$out" "status improved"
ok "merge node has two parents and scores 23"

# ------------------------------------------------------------------ verification and ranking
rc=0; as box1 box1_1 scripts/verify.sh "$n1" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "verifying your own node should exit 4 (got $rc)"
[ "$(as box2 box2_1 scripts/verify.sh "$n1" 2>/dev/null)" = 20 ] || fail "verify should reproduce 20"
out="$(as box1 box1_1 scripts/tree.sh best)"
has "$out" "Verified"; has "$out" "$n1 .* 20 .* verified"
ok "verification by another agent marks the node verified; own node refused"

handnode box1 "$n1" box1_1_liar a.txt 16 100
[ "$(as box2 box2_1 scripts/verify.sh box1_1_liar 2>/dev/null)" = 21 ] || fail "verify should reproduce 21"
out="$(as box2 box2_1 scripts/tree.sh show box1_1_liar)"
has "$out" "trust suspect  effective 21"
nc="$(experiment box1 box1_1 "" a.txt 17 "Build on the liar" box1_1_liar)"
out="$(as box2 box2_1 scripts/tree.sh show "$nc")"
has "$out" "trust inherits_suspect"
out="$(as box2 box2_1 scripts/tree.sh best)"
has "$out" "Suspect"; has "$out" "box1_1_liar .* 100 .* 21 .*suspect"
ok "wrong recorded score: suspect, re-ranked by reproduction; child inherits_suspect"
sed 's/^noise_threshold:.*/noise_threshold: 0.9\nnoise_mode: relative/' "$T/box2/task/config.yaml" > "$T/relative.yaml"
out="$(as box2 box2_1 env MYCELIUM_CONFIG="$T/relative.yaml" scripts/tree.sh show box1_1_liar)"
has "$out" "trust verified"
ok "noise_mode relative: the threshold scales with the score (|21 - 100| < 0.9 x 100)"

# ------------------------------------------------------------------ crash, duplicates, stale claims
ck="$(as box2 box2_1 scripts/claim.sh new --kind experiment --node "$n2" --description "Raise b to 9 and then crash before releasing.")"
( cd "$T/box2" && eval "$(scripts/launch.sh --print-env --agent-id box2_1)"
  w="$(scripts/checkout.sh "$n2" 2>/dev/null)"; echo 9 > "$w/b.txt"; scripts/evaluate.sh "$w" >/dev/null 2>&1
  MYCELIUM_TEST_SKIP_RELEASE=1 scripts/record.sh --worktree "$w" --summary "b=9" --description "Crash before release." --claim "$ck" >/dev/null 2>&1 )
out="$(as box1 box1_1 scripts/tree.sh claims --all)"
has "$out" "$ck .* done"
out="$(as box1 box1_1 scripts/tree.sh claims)"
hasnt "$out" "$ck"
ok "claim of a node pushed before a crash is treated as done"

export MYCELIUM_NOW=1900000000
d1="$(experiment box1 box1_1 "" a.txt 11 "Same second 1" root)"
d2="$(experiment box1 box1_1 "" a.txt 11 "Same second 2" root)"
unset MYCELIUM_NOW
[ "$d1" != "$d2" ] && has "$d2" "_1$" || fail "second node in the same second should get a new ID ($d1, $d2)"
ok "node ID collision retried with a new ID"
out="$(as box2 box2_1 scripts/tree.sh dupes)"
has "$out" "identical diffs from root: .*$d1.*$d2\|identical diffs from root: .*$d2.*$d1"
ok "dupes finds identical sibling diffs"

cs="$(as box2 box2_1 scripts/claim.sh new --kind experiment --node root --description "This claim will be abandoned and go stale.")"
out="$(as box1 box1_1 env MYCELIUM_NOW=$(( $(date -u +%s) + 100000 )) scripts/tree.sh status)"
has "$out" "Possibly dead agents"; has "$out" "$cs"
as box1 box1_1 env MYCELIUM_NOW=$(( $(date -u +%s) + 100000 )) scripts/claim.sh cleanup >/dev/null 2>&1
out="$(as box1 box1_1 scripts/tree.sh claims --all)"
hasnt "$out" "$cs"; hasnt "$out" "box1_1_racer"
ok "stale claims reported as possibly dead and cleaned up by another agent"

# force push of the claims branch is blocked by the hook
rc=0; out="$(cd "$T/box1" && eval "$(scripts/launch.sh --print-env --agent-id box1_1)" \
  && git fetch -q origin mycelium/e2e_run/claims && git push origin "+$(git rev-parse FETCH_HEAD~1):refs/heads/mycelium/e2e_run/claims" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && has "$out" "non-fast-forward" || fail "force push of the claims branch must be blocked"
ok "pre-push hook blocks force-pushing the claims branch"
rc=0; out="$(as box1 box1_1 sh -c 'git commit -q --allow-empty -m "edit task" && git push origin HEAD:refs/heads/main' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && has "$out" "only push the claims and notes" || fail "exploring agents must not push main"
ok "pre-push hook blocks exploring agents from pushing main"

# ------------------------------------------------------------------ notes, stats
printf 'Directions: raising a and b both help; merges stack.\n' > "$T/strategy.md"
out="$(as box2 box2_1 scripts/tree.sh status)"
has "$out" "strategy update due"
as box2 box2_1 scripts/note.sh strategy --file "$T/strategy.md" >/dev/null 2>&1
as box1 box1_1 scripts/note.sh board --title "Weights are protected" --text "Changing bench/ never helps: it is restored before scoring." >/dev/null 2>&1
out="$(as box1 box1_1 scripts/tree.sh notes)"
has "$out" "merges stack"; has "$out" "Weights are protected"
out="$(as box1 box1_1 scripts/tree.sh status)"
hasnt "$out" "strategy update due"; has "$out" "Notes board: 1 notes"
ok "strategy notes and the notes board"

out="$(as box1 box1_1 scripts/tree.sh stats)"
has "$out" "fake / scripted"; has "$out" "Compounding:"
ok "stats by agent/model and the compounding metric"

# ------------------------------------------------------------------ headless launch loop
cat > "$T/fake_agent.sh" <<'EOF'
#!/usr/bin/env bash
# A scripted stand-in for an LLM agent: one experiment per invocation.
set -euo pipefail
best="$(scripts/tree.sh tsv | awk -F'\t' '$15 != "invalid" && $15 != "failed" && $16 != "" { print $16 "\t" $1 }' | sort -gr | head -n 1 | cut -f2)"
c="$(scripts/claim.sh new --kind experiment --node "$best" --description "Fake agent: increment a by one on the best node.")"
w="$(scripts/checkout.sh "$best" 2>/dev/null)"
echo $(( $(cat "$w/a.txt") + 1 )) > "$w/a.txt"
scripts/evaluate.sh "$w" >/dev/null 2>&1 || true
scripts/record.sh --worktree "$w" --summary "Increment a" --description "Fake agent increments a." --claim "$c" >/dev/null 2>&1
EOF
chmod +x "$T/fake_agent.sh"
( cd "$T/box2" && MYCELIUM_AGENT_CMD="$T/fake_agent.sh" scripts/launch.sh --headless --agent fake --max-experiments 2 >/dev/null 2>&1 )
out="$(as box1 box1_1 scripts/tree.sh tsv | awk -F'\t' '$6 == "e2e_1"' | wc -l | tr -d ' ')"
[ "$out" = 2 ] || fail "headless loop should record 2 nodes as e2e_1 (got $out)"
ok "launch.sh --headless runs a fresh agent per experiment and stops at the budget"
out="$(cd "$T/box1/target" && git fetch -q origin '+refs/tags/*:refs/tags/*' && git for-each-ref 'refs/tags/mycelium/e2e_run/verify/*/e2e_1' --format='%(refname)' | wc -l | tr -d ' ')"
[ "$out" -ge 1 ] || fail "headless loop should verify other agents' nodes (got $out verify tags by e2e_1)"
ok "launch.sh --headless verifies other agents' best nodes before iterations"

top="$(as box1 box1_1 scripts/tree.sh frontier | sed -n 3p)"
has "$top" " 25 "
ok "frontier is ranked best first"

echo
echo "All $PASS checks passed."
