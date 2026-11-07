# Mycelium agent instructions

This repository is a Mycelium experiment campaign: many agents improve a
target codebase (`target/`, a Git submodule) against a fixed score, and
coordinate only through Git. `AGENTS.md` is a symlink to this file, so every
agent reads the same instructions.

## Choose your mode first

1. **Exploring mode.** `MYCELIUM_MODE=exploring` is set in your environment,
   which `scripts/launch.sh` does. Read `skills/mycelium/SKILL.md` and follow
   its experiment loop. Ignore the rest of this file.
2. **Onboarding mode.** Otherwise, run `scripts/onboard.sh status`. If any step
   other than the optional pilot is unchecked, the run is not ready: follow
   **Onboarding** below with the user, continuing from the first unchecked step.
3. **Observer mode.** Otherwise the run is ready, and this is a human's
   interactive session. Answer questions about the run with
   `scripts/tree.sh status`, `best`, `show` and `stats`, as the skill describes
   under "Answering status questions". To start exploring agents, tell the user
   to run `scripts/launch.sh` on each machine. Use `--headless` only inside a
   container or VM.

## Onboarding

Onboarding is an interactive setup conversation with the user. Explain what you
are doing as you go, ask before anything outward-facing (forking, pushing), and
commit to the Mycelium repo as you complete steps. It is resumable:
`scripts/onboard.sh status` shows what is done.

### 1. Set up the target

Ask the user for the target repository: what they want to improve, and the
URL. Then fork it to get the *exploration fork*, where agents will push nodes:

- If `gh` is installed and logged in, run `gh repo fork <owner>/<repo> --clone=false`.
  Otherwise ask the user to fork it in the browser and paste the URL.
- If the user already has a fork, GitHub returns it. Tell the user that nodes
  will be pushed there as namespaced tags, which is harmless.
- Tell the user that a fork of a public repository is public, so every
  experiment, including failures, will be visible. If that is not acceptable,
  create a private repository instead and push the baseline commit into it.
- Ask which commit is the baseline (default: the current default branch).
- Add the fork as a submodule, pinned to the baseline, and commit:

  ```
  git submodule add <fork-url> target
  git -C target checkout <baseline>
  git add .gitmodules target && git commit -m "Add target submodule"
  ```

  Fill in `target_upstream`, `target_fork` and `target_baseline` in `task/config.yaml`.

- If `target/` already exists but points at the upstream repository (as in a
  ready-made example), keep the pinned commit and only switch the URL to the fork:

  ```
  git submodule set-url target <fork-url> && git submodule sync
  git -C target fetch origin
  ```

  Then set `target_fork` in `task/config.yaml` and commit.

### 2. Write `task/TASK.md` with the user

Cover the goal, what may and may not be changed, hints, known dead ends and
constraints. Read the target code first so you can suggest specifics.

### 3. Write `task/score.sh` with the user

The score is the foundation of the whole search. It must be:

- **cheap**: it will run hundreds of times;
- **consistent**: pin seeds, data, thread counts and hardware where possible;
- **hard to game**: keep benchmarks, test data and reference outputs in `task/`
  (outside the target) where practical, and list everything in the target that
  the score depends on in `protected_paths`;
- **directional**: higher or lower is better.

Contract: `score.sh <dir>` gets a clean export of the candidate code. It prints
the score as a single number on the last line of stdout and logs to stderr. It
exits non-zero if the candidate fails to build, crashes or is incorrect. It
receives `MYCELIUM_SEED`, `MYCELIUM_BUDGET_SECONDS` and `MYCELIUM_TASK_DIR`.

If no clean numeric metric exists, a test-suite pass rate or an LLM judge can
work, but warn the user that the search will be noisier.

Then record `direction`, `seed`, `eval_budget_seconds`, `data_version` and
`protected_paths` in `task/config.yaml`, and measure the noise:

```
scripts/onboard.sh noise 5
```

Each evaluation runs `score.sh` `eval_repeats` times (default 3) and takes
the median, so the noise measured here is that of the median. Use
`eval_repeats: 1` if the score is deterministic (e.g. a test pass rate).
Set `noise_threshold` from its suggestion and report the observed noise to the
user. Choose `noise_mode: relative` (the threshold is a fraction of the score)
when the noise grows with the score, as it does for speedups, times and
throughputs; otherwise keep `absolute`. If the noise is large relative to the improvements you expect, work with
the user to make the score more stable before continuing.

### 4. Choose a `run_id`

Choose it with the user: snake_case, e.g. `perf_2026_11`. Set it in
`task/config.yaml`.

### 5. Score the baseline and create the root node

```
scripts/onboard.sh root
```

### 6. Offer a pilot

Ask: "Would you like to do a few test iterations on the prompt before
launching?" Actively recommend a pilot if `score.sh` is new or `TASK.md` is
vague.

### 7. Pilot loop (optional)

1. Temporarily set `run_id` in `task/config.yaml` to `<run_id>_pilot_1`, then
   run `scripts/onboard.sh root` for the pilot run.
2. Run 2–3 experiments yourself, following `skills/mycelium/SKILL.md` exactly,
   as an exploring agent would.
3. Review them with the user: what you tried, where you got confused, how the
   scores looked, and whether tagging and committing worked.
4. Revise `TASK.md` (and the skill or config if needed) together, then repeat
   with `_pilot_2`, and so on, until the user is satisfied.
5. Set `run_id` back to the real run ID. Pilot nodes stay in their own
   namespace and never mix with the real run.

### 8. Mark the run ready

Commit the final task files, then:

```
scripts/onboard.sh ready
```

This pushes the Mycelium repo and the tag `mycelium/<run_id>/ready`.
`launch.sh` refuses to start without that tag. Tell the user how to launch:

```
git clone --recurse-submodules <mycelium-fork-url> && cd <repo>
scripts/launch.sh                  # interactive, or:
scripts/launch.sh --headless --max-experiments 20   # unattended, in a container/VM
```
