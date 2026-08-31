#!/usr/bin/env bash
# Enforces the D2 vocabulary rule: Doot is not a key-value store, so the words are
# not available. See docs/00-vision.md for the full mapping table.
#
# Deliberately narrow. A general ban on "key" is unworkable — "API key",
# "Idempotency-Key", "index hash key", "keep-alive" and "keyed hash" are all
# legitimate and frequent. So this bans only tokens that cannot be innocent, which
# catches the specific drift D2 fears: the vocabulary sliding back toward
# "key-value store". It is honest about not catching subtler slippage. A check with
# no false positives that runs on every commit beats a thorough one that gets
# switched off.
#
# Usage: tools/vocab-check.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# docs/00-vision.md defines the prohibition and docs/07-decisions.md argues it, so
# both quote the banned terms on purpose. Excluding exactly those two files keeps the
# check meaningful everywhere the vocabulary is actually used.
mapfile -t files < <(
  git ls-files \
    | grep -v -E '^(docs/00-vision\.md|docs/07-decisions\.md|tools/vocab-check\.sh)$'
)

patterns=(
  'key[-_ ]value'
  'keyvalue'
  '/v1/kv'
  '\bkv\b'
)

status=0
for p in "${patterns[@]}"; do
  if hits=$(grep -RInE --color=never "$p" -- "${files[@]}" 2>/dev/null); then
    echo "!!! D2 vocabulary violation: /$p/" >&2
    echo "$hits" | sed 's/^/    /' >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "D2 vocabulary check: clean (${#files[@]} tracked files)"
else
  echo >&2
  echo "Doot stores entries addressed by a name, holding a body, grouped by tags." >&2
  echo "See docs/00-vision.md for the replacement vocabulary." >&2
fi
exit "$status"
