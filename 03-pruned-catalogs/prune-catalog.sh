#!/usr/bin/env bash
set -euo pipefail

# Prune an FBC catalog to keep only specified packages/channels/bundles.
# Usage: ./prune-catalog.sh <catalog.json> <package> <channel> <bundle-name> [<bundle-name>...]
#
# Example:
#   ./prune-catalog.sh catalog.json my-operator stable-2.x my-operator.v2.5.3
#
# Output: writes pruned FBC to configs/index.json (creates configs/ if needed)

CATALOG="$1"; shift
PACKAGE="$1"; shift
CHANNEL="$1"; shift
BUNDLES=("$@")

mkdir -p configs

BUNDLE_SELECT=""
for b in "${BUNDLES[@]}"; do
  if [[ -n "$BUNDLE_SELECT" ]]; then
    BUNDLE_SELECT="$BUNDLE_SELECT or"
  fi
  BUNDLE_SELECT="$BUNDLE_SELECT (.name == \"$b\")"
done

BUNDLE_FILTER=""
for b in "${BUNDLES[@]}"; do
  if [[ -n "$BUNDLE_FILTER" ]]; then
    BUNDLE_FILTER="$BUNDLE_FILTER or"
  fi
  BUNDLE_FILTER="$BUNDLE_FILTER (.schema == \"olm.bundle\" and $BUNDLE_SELECT)"
done

jq -c "
select(
  (.schema == \"olm.package\" and .name == \"$PACKAGE\")
  or
  (.schema == \"olm.channel\" and .package == \"$PACKAGE\" and .name == \"$CHANNEL\")
  or
  (.schema == \"olm.bundle\" and .package == \"$PACKAGE\" and ($BUNDLE_SELECT))
)
|
if .schema == \"olm.package\" then
  .defaultChannel = \"$CHANNEL\"
elif .schema == \"olm.channel\" then
  .entries = [.entries[] | select($BUNDLE_SELECT) | {name, replaces, skipRange}]
else . end
" "$CATALOG" > configs/index.json

echo "Pruned catalog written to configs/index.json"
echo "Validate with: opm validate configs/"
