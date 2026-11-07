#!/usr/bin/env bash
# Fixed scoring script. Written during onboarding; exploring agents must never edit it.
#
# Contract (see skills/mycelium/SKILL.md):
#   usage:   score.sh <dir>     <dir> is a clean export of the candidate target code
#   env:     MYCELIUM_SEED, MYCELIUM_BUDGET_SECONDS, MYCELIUM_TASK_DIR (this task/ dir),
#            MYCELIUM_DATA_VERSION
#   output:  the score as a single number on the LAST line of stdout; logs go to stderr
#   exit:    non-zero if the candidate fails to build, crashes or is incorrect
#
# Make it cheap, deterministic (pin seeds, data, threads) and hard to game.
set -euo pipefail
echo "task/score.sh has not been written yet (run onboarding)" >&2
exit 1
