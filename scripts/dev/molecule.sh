#!/usr/bin/env bash
# Run Molecule (converge + idempotence + verify) for one role or all testable roles.
#   scripts/dev/molecule.sh            # all
#   scripts/dev/molecule.sh security   # one
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
roles=("${@:-base security docker selfheal backup}")
read -r -a roles <<< "${roles[*]}"
failed=()
for role in "${roles[@]}"; do
  echo "================ molecule test: $role ================"
  if ! (cd "$ROOT/ansible/roles/$role" && molecule test); then
    failed+=("$role")
  fi
done
if (( ${#failed[@]} )); then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "All Molecule scenarios passed: ${roles[*]}"
