#!/usr/bin/env bash
set -euo pipefail
# `hello` comes from the skill's `scriptInputs`, not the caller's PATH.
hello --greeting="greet.sh found hello"
