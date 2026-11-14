#!/usr/bin/env bash
# mask-secrets.sh <dir> — replace ATATUS_LICENSE_KEY and MAESTRO_SEED_PASSWORD with *** in every text file under <dir>.
set -euo pipefail

DIR="${1:?dir}"
[[ -d "$DIR" ]] || exit 0
for secret in "${ATATUS_LICENSE_KEY:-}" "${MAESTRO_SEED_PASSWORD:-}"; do
  [[ -n "$secret" ]] || continue
  grep -rlIF -- "$secret" "$DIR" | while IFS= read -r file; do
    SECRET="$secret" perl -pi -e 's/\Q$ENV{SECRET}\E/***/g' "$file"
  done || true
done
if [[ -n "${ATATUS_LICENSE_KEY:-}" ]] && grep -rqIF -- "$ATATUS_LICENSE_KEY" "$DIR"; then
  echo "::error::ATATUS_LICENSE_KEY still present in $DIR"; exit 1
fi
