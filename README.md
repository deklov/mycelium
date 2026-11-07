# Mycelium

Run many AI coding agents (Claude Code, Codex or a mix) on many machines,
exploring improvements to a codebase against a measurable score. They
coordinate **only through Git**: no server, no database, no orchestrator.

Mycelium turns the single-agent *autoresearch* loop (edit, score, keep or
revert) into a **shared tree search**:

- Every experiment, **including failures**, becomes a permanent node in a tree,
  so nothing is forgotten and nobody retries a known dead end by accident.
- Any agent can branch from any node, not just the latest best, so promising
  older states get revisited.
- Agents announce work before starting it (claims), verify each other's
  results, merge branches whose improvements stack, and leave notes.

## Quick start

1. **Fork this repository** on GitHub and clone your fork.
2. **Start Claude Code** (or Codex, or a similar agent) in the checkout.

The agent sees that the run isn't set up and walks you through **onboarding**:

1. It forks the target repository for you.
2. You write the task description and a fixed scoring script together.
3. It measures the score's noise, scores the baseline and offers a short pilot.
4. It marks the run ready.

Then, on each machine:

```
git clone --recurse-submodules <your-mycelium-fork> && cd <it>
scripts/launch.sh                                  # interactive agent
scripts/launch.sh --headless --max-experiments 20  # unattended; only in a container or VM
```

Ask any running agent "What's the status?" and it summarises who is doing
what, the best verified results and anything suspicious. You can also run
`scripts/tree.sh status` yourself.

## How it works

### The score

Everything rests on a fixed scoring script, `task/score.sh`. It must be
**cheap** (it runs hundreds of times), **consistent** (pinned seeds, data and
threads), **hard to game** (agents cannot edit it, or anything it depends on)
and **directional** (higher or lower is better). Agents never measure the score
themselves. `scripts/evaluate.sh` runs the script on an exact snapshot of the
candidate, after restoring every protected file from the baseline. It runs the
script several times (`eval_repeats`, default 3) and records the median, with
every repeat's score kept in the node.

### The tree lives in the target repository

Each node is a commit in the target repository (in practice, in your fork of
it). Its Git parents are the nodes it was built from, so Git's commit graph
*is* the experiment tree. Every node is tagged, which makes nodes easy to find
and stops Git from garbage-collecting failed experiments.

| Ref | Where | Purpose |
| --- | --- | --- |
| `mycelium/<run_id>/node/<node_id>` | target fork | one tag per node; `node/root` is the baseline |
| `mycelium/<run_id>/verify/<node_id>/<agent_id>` | target fork | annotated tag: a reproduction of a node's score |
| `mycelium/<run_id>/claims` | Mycelium fork | branch of open claims, `claims/<claim_id>.md` |
| `mycelium/<run_id>/notes` | Mycelium fork | branch with `strategy.md` and `board/<note_id>.md` |
| `mycelium/<run_id>/ready` | Mycelium fork | tag: onboarding finished |

All identifiers are snake_case (`[a-z0-9_]+`). A `run_id` keeps separate
campaigns apart, so one fork can host many runs.

A node's score and metadata are Git trailers in its commit message:

```
Raise matmul tile size to 64

Tiling the inner loop at 64 instead of 32 keeps both operands in L1 on this
CPU; +9% tokens/s. 128 was slower (see sibling node).

Mycelium-Run: perf_2026_11
Mycelium-Node: box2_1_20261105_143201
Mycelium-Parent: box1_1_20261105_130155
Mycelium-Claim: box2_1_20261105_142901
Mycelium-Score: 412.7
Mycelium-Status: improved
Mycelium-Agent-Id: box2_1
Mycelium-Agent: claude_code
Mycelium-Model: claude-opus-5-5
Mycelium-Machine: box2
Mycelium-Seed: 1234
```

A merge node lists one `Mycelium-Parent` per parent. Nothing is ever indexed
or stored in order: every view is recomputed from the refs, which takes well
under a second for thousands of nodes.

### Claims: avoiding duplicate work

Before starting any work (an experiment, a verification, a merge, a strategy
update), an agent pushes a small claim file to the claims branch. Git only
accepts fast-forward pushes, so when two agents claim at the same moment, one
push is rejected. That agent must re-read the new claims and make sure its
idea is still clearly different before retrying. This works on any Git host
with no server-side configuration.

Claims expire if they are not renewed, so crashed agents clean up after
themselves. A local `pre-push` hook and read-time validation catch malformed
claims and agents removing other agents' live claims.

### Verification and trust

Before building on a node, an agent checks that someone other than its author
has reproduced the node's score. Ranking uses each node's **trust**:

| Trust | Meaning | Ranked by |
| --- | --- | --- |
| `verified` | reproduced within the noise threshold | mean of all scores |
| `unverified` | not reproduced yet | recorded score |
| `suspect` | reproduction disagrees | the reproduced score |
| `inherits_suspect` | an ancestor is suspect | recorded score, but needs its own verification |
| `failed` / `invalid` | did not score / malformed or touches protected files | not ranked |

Only verified nodes are reported as **the best**.

Verification needs no LLM, so in unattended runs `launch.sh` does it itself:
before each experiment it re-scores the best-ranked node of *another* agent
that is still unverified. Every agent therefore verifies the others' best
work, whatever the agents themselves choose to do.

### Robustness

Shared state is append-only, apart from temporary claim files. Every write is a
single push: pushing a node's tag uploads the commit and the tag together.
Local work is disposable, and readers validate everything they read. A crash
at any point loses at most one experiment and leaves the shared state valid.

## Repository layout

```
CLAUDE.md                  agent instructions: onboarding, exploring and observer modes
AGENTS.md -> CLAUDE.md     the same instructions for Codex and other agents
skills/mycelium/SKILL.md   the exploring agent's manual (also at .claude/skills/)
task/TASK.md               the problem: goal, what may change, hints, dead ends
task/score.sh              the fixed scoring script
task/config.yaml           run_id, direction, noise, budgets, protected paths
scripts/launch.sh          start an exploring agent (checks readiness and push access)
scripts/tree.sh            read the tree: status, best, frontier, show, claims, stats, ...
scripts/claim.sh           claim, renew, release and clean up claims
scripts/checkout.sh        a fresh worktree at a node (or a merge of several)
scripts/evaluate.sh        score a worktree with the fixed script
scripts/record.sh          commit, tag and push a node, then release the claim
scripts/verify.sh          re-score a node and push its verify tag
scripts/note.sh            strategy notes and the notes board
scripts/onboard.sh         onboarding helpers: status, noise, root, ready
hooks/pre-push             local checks on claim and notes pushes
tests/e2e.sh               end-to-end test of all of the above
target/                    the repository being optimised (added during onboarding)
```

The scripts are portable bash using only Git (2.30 or later) and standard Unix
tools. They are conveniences: `skills/mycelium/SKILL.md` documents the
underlying Git operations, so an agent could do everything by hand.

## Testing

```
tests/e2e.sh
```

This builds a synthetic target, local bare repositories standing in for the
forks, and two simulated machines in a temp directory. Scripted agents then
exercise:

- claim races;
- failed nodes and merges;
- verification and suspects;
- protected paths;
- stale claims;
- the pre-push hook;
- the headless launch loop.

It needs no network or LLM, runs in seconds, and never touches this repository.

## Example

[`mycelium_example_llama2c`](https://github.com/deklov/mycelium_example_llama2c)
is a Mycelium fork that is already set up to make
[llama2.c](https://github.com/karpathy/llama2.c) inference faster on CPU,
without changing its output.

## Related work

Mycelium builds on Karpathy's
[autoresearch](https://github.com/karpathy/autoresearch). Similar systems
include:

- [autoresearch-at-home](https://github.com/mutable-state-inc/autoresearch-at-home)
- [AgentHub](https://github.com/ottogin/agenthub)
- GitSwarm
- [CORAL](https://github.com/Human-Agent-Society/CORAL)
- [evo](https://github.com/evo-hq/evo)

Mycelium's angle is a fork-and-go template that needs only an ordinary Git
remote, works across any number of machines, and accepts any mix of agents.

## License

MIT
