---
name: mycelium
description: How to explore a Mycelium run, a shared experiment tree stored in Git. Use it to read the tree, choose where to branch, claim work, run and record experiments, verify nodes, write notes, and answer status questions.
---

# Mycelium: exploring a shared experiment tree

Several agents, possibly on different machines, improve a target codebase
against a fixed score. They coordinate only through Git. There is no server.
**The tree is your only memory**: each experiment starts with a fresh context,
so read the tree before deciding anything, and write descriptions that the next
agent can learn from.

## Concepts

- **Run**: one campaign, `run_id` in `task/config.yaml`.
- **Node**: one experiment, a commit in the target repo (`target/`) tagged
  `mycelium/<run_id>/node/<node_id>`. Its score and metadata are Git trailers
  in the commit message. The Git parents are the nodes it was built from, so
  Git's commit graph *is* the tree. Every experiment is a node, **including
  failures**. The baseline is the node `root`.
- **Verification**: another agent re-scores a node and pushes the annotated tag
  `mycelium/<run_id>/verify/<node_id>/<agent_id>`.
- **Trust** (computed at read time):
  - `verified`: reproduced within `noise_threshold`.
  - `unverified`: not yet reproduced.
  - `suspect`: reproduction disagreed. It is ranked by the reproduced score.
  - `inherits_suspect`: an ancestor is suspect. Verify the node before trusting it.
  - `failed`: the experiment did not build, run or score.
  - `invalid`: malformed, or touches a protected path. Ignored.
- **Claim**: a small file on the Mycelium repo's branch `mycelium/<run_id>/claims`
  announcing work in progress, so others don't duplicate it. Claims expire if
  they are not renewed.
- **Notes**: the branch `mycelium/<run_id>/notes` holds `strategy.md` (a
  periodic summary of the tree) and `board/*.md` (lessons).

Your identity comes from the environment that `scripts/launch.sh` sets:
`MYCELIUM_AGENT_ID`, `MYCELIUM_RUN_ID` and `MYCELIUM_MODEL`.

## Rules

1. Never edit `task/` (score.sh, TASK.md, config.yaml), `skills/`, `scripts/`,
   `hooks/` or `CLAUDE.md`, and never commit to or push the Mycelium repo's main
   branch. You write to the Mycelium repo only through `claim.sh` and `note.sh`.
2. Never modify a file in `protected_paths` (see `task/config.yaml`). Those
   files are restored before scoring and such nodes are rejected.
3. Score only with `scripts/evaluate.sh`. Never measure the score your own way,
   and never type a score in. `record.sh` takes it from the evaluation.
4. Never rewrite, delete or force-push nodes, tags, or the claims or notes
   branches. Never use `--no-verify` or `--force`.
5. Record every experiment, including failures and no-improvement results.
6. Work only in worktrees made by `scripts/checkout.sh`, never in `target/`
   itself.
7. Read `task/TASK.md` before your first change: the goal, what may be
   changed, hints and known dead ends.

## The experiment loop

Run one iteration. If you were started headless, stop after one iteration.

### 1. Read the tree

```
scripts/tree.sh status            # who is doing what, recent results, best, notes
scripts/tree.sh frontier          # ranked candidates: score, trust, children, open claims
scripts/tree.sh claims            # open claims, with descriptions
scripts/tree.sh notes             # strategy notes and the notes board
scripts/tree.sh show <node_id>    # a node's full description, ancestry, children, diffstat
scripts/tree.sh children <node_id>  # what has been tried from a node, including failures
```

All views fetch first and are recomputed from Git.

### 2. Choose what to do

Nothing is prescribed; use your judgement and your knowledge of the domain. Options:

- **Extend** a node: change something on top of it.
- **Merge** nodes from different branches whose improvements might stack.
- **Verify** a promising node that is unverified or `inherits_suspect`
  (`scripts/verify.sh <node_id>`). See step 2a.
- **Write strategy notes** when `tree.sh status` says an update is due (step 9).

Suggestions:

- Balance exploiting the best nodes with exploring promising, little-expanded
  ones. A node with a good score and few children is often a good bet.
- If a line of work has stopped improving after several attempts, step back and
  choose again from the whole tree.
- Read the children of your starting node (`tree.sh children`) and the open
  claims. **Your idea must be clearly different** from what has been tried and
  what others are doing now. Failed children are especially informative.
- Add some randomness: don't always take the top node, or every agent piles
  onto it.
- Prefer one clear idea per experiment, so the result teaches something.

### 2a. Verify the starting node first

If your starting node (other than `root`) is not `verified`, and nobody has an
open `verify` claim on it, verify it before building on it:

```
scripts/verify.sh <node_id>
```

It claims, re-scores, pushes the verify tag and releases the claim in one step.
Exit 4 means there is nothing to do: it's your own node, you already verified
it, or someone else is verifying it.

In headless mode `launch.sh` also runs `scripts/verify.sh --next` before each
iteration, which verifies the best unverified node of another agent, so most
top nodes get verified without you. `scripts/verify.sh --next` works by hand too.

You may build on an unverified node optimistically when verification is slow
and you are reasonably confident: a large gain relative to the noise, or
children that score well.

If verification shows the node is suspect, choose again.

### 3. Claim

```
CLAIM=$(scripts/claim.sh new --kind experiment --node <node_id> \
  --description "<one paragraph: what you will change and why>")
```

For a merge, use `--kind merge --node <a>,<b>`.

**Exit code 3** means other agents posted claims at the same moment, and they
are printed. Read them. If your idea still clearly differs, run the same command
again. Otherwise change your idea or your starting node first.

Claims expire when they are not renewed within the claim timeout (default 3 x
`eval_budget_seconds`). If your work takes longer than that, renew the claim
with `scripts/claim.sh renew $CLAIM`, for example after each evaluation.

### 4. Check out a fresh worktree

```
WT=$(scripts/checkout.sh <node_id>)            # extend
WT=$(scripts/checkout.sh <node_a> <node_b>)    # merge: resolve conflicts if reported
```

### 5. Make the change

Edit files under `$WT` only, and keep within what TASK.md allows. Building or
testing inside `$WT` is fine, but **delete build outputs and scratch files
before evaluating**: everything left in the worktree is recorded in the node,
unless it is ignored by `.gitignore` or `ignore_paths`. `record.sh` refuses new
binary files.

### 6. Evaluate

```
scripts/evaluate.sh "$WT"
```

It runs the score `eval_repeats` times (default 3) and prints the median on the
last line, or `failed` with the end of the log. Full logs are in
`.work/eval/<tree>.log`.

If it fails because of a bug you can fix, fix it and evaluate again. If your
idea doesn't work, that's a result: record it. Evaluate again after every
change, because `record.sh` only accepts a score for exactly the tree being
committed.

### 7. Record (always, whatever the result)

```
scripts/record.sh --worktree "$WT" --claim "$CLAIM" \
  --summary "<one line: the idea>" \
  --description "<what you changed, why, the result, and what you learned>"
```

Add `--failed` if the change does not build or score and you are giving up on
it. `record.sh` takes the score from the evaluation, computes the status
(`improved` / `no_improvement` against the best parent, using the noise
threshold), commits, tags, pushes and releases your claim.

If `MYCELIUM_MODEL` is `unknown`, export `MYCELIUM_MODEL=<your model id>` in
the same command.

The description is what the next agent reads, so make it useful. Include
numbers, the hypothesis, and for failures *why* it failed and what to avoid.

If a push fails, `record.sh` prints how to retry. If it says the node ID was
taken, it retries with a new ID by itself.

### 8. Notes (when you learned something general)

```
scripts/note.sh board --title "<short title>" --text "<the lesson>"
```

Use this for lessons that aren't tied to one node, e.g. "unrolling beyond 4
never helps on this CPU".

### 9. Strategy notes (when `tree.sh status` says an update is due)

1. Claim it: `scripts/claim.sh new --kind strategy --node tree --description "Update strategy notes"`.
2. Read the whole tree.
3. Write a short summary to a file: the main directions tried, how each did,
   what seems exhausted, what is underexplored, and the best verified nodes.
4. Run `scripts/note.sh strategy --file <file> --claim <claim_id>`.

## Answering status questions

If a human asks "What's the status?" or "What is everyone working on?":
1. Pause your work.
2. Run `scripts/tree.sh status` (and `scripts/tree.sh best` if they ask about
   results).
3. Give a short plain-language summary: who is working on what, recent results,
   the best verified score versus the baseline, suspect nodes, and possibly
   dead agents.
4. Carry on with your work.

## Raw Git (if the scripts are unavailable)

The tree is plain Git, and the scripts are only conveniences:

```
git -C target fetch origin '+refs/tags/mycelium/<run_id>/*:refs/tags/mycelium/<run_id>/*'
git -C target for-each-ref refs/tags/mycelium/<run_id>/node/ --format='%(refname:lstrip=5) %(objectname)'
git -C target log -1 --format='%B' mycelium/<run_id>/node/<node_id>     # description + trailers
git fetch origin mycelium/<run_id>/claims && git ls-tree -r FETCH_HEAD claims/
```

A node commit message ends with trailers:

```
Mycelium-Run: <run_id>
Mycelium-Node: <node_id>              # <agent_id>_<YYYYmmdd_HHMMSS>
Mycelium-Parent: <node_id>            # once per parent; none for root
Mycelium-Claim: <claim_id>
Mycelium-Score: <number>              # median of the repeats; absent if failed
Mycelium-Score-Runs: <n>,<n>,<n>      # every repeat's score
Mycelium-Status: baseline | improved | no_improvement | failed
Mycelium-Agent-Id: <agent_id>
Mycelium-Agent: claude_code | codex | ...
Mycelium-Model: <model>
Mycelium-Machine: <machine>
Mycelium-Seed: <seed>
```

Pushes:
- A node is pushed with `git -C target push origin refs/tags/mycelium/<run_id>/node/<node_id>`,
  which uploads the commit and the tag together. A rejected tag push means the
  ID is taken: choose a new one.
- A claim is a commit on the claims branch adding `claims/<claim_id>.md`. A
  rejected branch push means someone else pushed first: fetch, re-read the
  claims, then retry.
