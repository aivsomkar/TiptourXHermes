#!/usr/bin/env bash

# scripts/validate-bundled-skills.sh
#
# Run the upstream `skills-ref` validator over every bundled
# SKILL.md folder. Verifies the bundled RuFlo + OpenWork files
# still conform to the agentskills.io spec
# (https://agentskills.io/specification).
#
# Usage:
#   ./scripts/validate-bundled-skills.sh
#
# `skills-ref` is a Node CLI shipped at
# https://github.com/agentskills/agentskills/tree/main/skills-ref
# Install (one-time):
#   npm install -g skills-ref
# or run via npx without installing globally.

set -euo pipefail

# Resolve repo root from this script's location so it works no matter
# where the caller invokes it from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLED_DIR="${REPO_ROOT}/TipTour/Agents/Skills/BundledSkills"

if [[ ! -d "${BUNDLED_DIR}" ]]; then
    echo "error: bundled skills directory not found at ${BUNDLED_DIR}" >&2
    exit 1
fi

# Pick the invocation form: prefer a globally installed `skills-ref`,
# fall back to `npx --yes skills-ref` so the script works on machines
# without a global install.
if command -v skills-ref >/dev/null 2>&1; then
    SKILLS_REF=(skills-ref)
elif command -v npx >/dev/null 2>&1; then
    SKILLS_REF=(npx --yes skills-ref)
else
    echo "error: neither 'skills-ref' nor 'npx' is on PATH" >&2
    echo "       install Node.js (https://nodejs.org) or skills-ref directly:" >&2
    echo "       npm install -g skills-ref" >&2
    exit 1
fi

total=0
failed=0
failed_skills=()

# `find -print0` + read -d '' so paths with spaces survive the loop.
while IFS= read -r -d '' skill_md; do
    total=$((total + 1))
    skill_dir="$(dirname "${skill_md}")"
    if ! "${SKILLS_REF[@]}" validate "${skill_dir}" >/dev/null 2>&1; then
        failed=$((failed + 1))
        failed_skills+=("${skill_dir#${REPO_ROOT}/}")
    fi
done < <(find "${BUNDLED_DIR}" -name SKILL.md -print0)

echo "validated ${total} bundled skill(s)"
if (( failed > 0 )); then
    echo "${failed} skill(s) failed validation:" >&2
    printf '  - %s\n' "${failed_skills[@]}" >&2
    exit 1
fi
echo "all bundled skills pass agentskills.io spec validation"
