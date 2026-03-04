#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT: resolve-operator-path.sh (v7)
# PURPOSE:  Consultant-grade OLM Path Solver.
# FEATURES: 
#   1. Floating Heads (minVersion only) for maximum graph stability.
#   2. Real Channel Names (No guessing).
#   3. Shortest Path (BFS) to minimize total hops.
# ==============================================================================

if (( BASH_VERSINFO[0] < 4 )); then
  echo "❌ Error: This script requires Bash 4+ (associative arrays)."
  echo "On macOS, install a newer Bash or run it on a Linux host."
  exit 1
fi

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Usage: $0 <OPERATOR> <CURRENT_VER> <TARGET_VER> <CATALOG_FILE> [CATALOG_IMAGE]"
  echo "Example: $0 advanced-cluster-management 2.11.4 2.13.5 catalog.json registry.redhat.io/redhat/redhat-operator-index:v4.18"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not installed or not on PATH."
  exit 1
fi

OPERATOR=$1
CURRENT_VER=$2
TARGET_VER=$3
CATALOG_FILE=$4
CATALOG_IMAGE=${5:-registry.redhat.io/redhat/redhat-operator-index:v4.16}

# ==============================================================================
# 1. EXTRACT DATA (Channel-Aware)
# ==============================================================================
# We extract the REAL channel name directly from the JSON stream.
TMP_GRAPH=$(mktemp)
trap 'rm -f "$TMP_GRAPH"' EXIT

jq -r --arg pkg "$OPERATOR" '
  select(.schema == "olm.channel" and .package == $pkg) |
  .name as $chan |
  .entries[] |
  [.name, $chan, (.replaces // ""), (.skipRange // "")] |
  @tsv
' "$CATALOG_FILE" > "$TMP_GRAPH"

if [[ ! -s "$TMP_GRAPH" ]]; then
  echo "❌ Error: No data found for $OPERATOR in $CATALOG_FILE"
  exit 1
fi

# Load into Memory
declare -A NODE_CHANNEL
declare -A NODE_REPLACES
declare -A NODE_SKIPRANGE
declare -A NODE_VERSION
ALL_ENTRY_IDS=()
TARGET_MATCHES=0

short_ver_from_bundle() {
  local bundle_name=$1
  printf '%s\n' "${bundle_name##*.v}"
}

while IFS=$'\t' read -r name channel replaces skipRange; do
  [[ -z "$name" ]] && continue

  SHORT_VER=$(short_ver_from_bundle "$name")
  ENTRY_ID="${channel}|${name}"

  NODE_CHANNEL["$ENTRY_ID"]=$channel
  NODE_REPLACES["$ENTRY_ID"]=$replaces
  NODE_SKIPRANGE["$ENTRY_ID"]=$skipRange
  NODE_VERSION["$ENTRY_ID"]=$SHORT_VER
  ALL_ENTRY_IDS+=("$ENTRY_ID")

  if [[ "$SHORT_VER" == "$TARGET_VER" ]]; then
    TARGET_MATCHES=$((TARGET_MATCHES + 1))
  fi
done < "$TMP_GRAPH"

# Verify Targets
if [[ "$TARGET_MATCHES" -eq 0 ]]; then
  echo "❌ Error: Target version $TARGET_VER not found in catalog."
  exit 1
fi

# Sort Descending (Newest First) for Greedy Optimization
SORT_INPUT=()
for ENTRY_ID in "${ALL_ENTRY_IDS[@]}"; do
  SORT_INPUT+=("${NODE_VERSION[$ENTRY_ID]}|$ENTRY_ID")
done
IFS=$'\n' SORTED_ENTRY_IDS=($(printf '%s\n' "${SORT_INPUT[@]}" | sort -t'|' -k1,1Vr -k2,2 | cut -d'|' -f2-))
unset IFS

# ==============================================================================
# 2. HELPER FUNCTIONS
# ==============================================================================
ver_gte() {
  local sorted=$(echo -e "$1\n$2" | sort -V | head -n1)
  [[ "$sorted" == "$2" ]]
}

check_range() {
  local ver=$1
  local range_str=$2
  if [[ "$range_str" == "None" || -z "$range_str" ]]; then return 1; fi
  
  for cond in $range_str; do
    local op=$(echo "$cond" | sed -E 's/([<>=]+).*/\1/')
    local limit=$(echo "$cond" | sed -E 's/[<>=]+(.*)/\1/')
    case "$op" in
      ">=") if ! ver_gte "$ver" "$limit"; then return 1; fi ;;
      "<=") if ! ver_gte "$limit" "$ver"; then return 1; fi ;;
      ">")  if [[ "$ver" == "$limit" ]] || ! ver_gte "$ver" "$limit"; then return 1; fi ;;
      "<")  if [[ "$ver" == "$limit" ]] || ! ver_gte "$limit" "$ver"; then return 1; fi ;;
    esac
  done
  return 0
}

# ==============================================================================
# 3. BFS SOLVER
# ==============================================================================
declare -A PARENT
declare -A VISITED
QUEUE=("START")
VISITED["START"]=1
FOUND_PATH=false
FOUND_NODE=""

while [ ${#QUEUE[@]} -gt 0 ]; do
  CURRENT=${QUEUE[0]}
  QUEUE=("${QUEUE[@]:1}")

  if [[ "$CURRENT" == "START" ]]; then
    CURRENT_SHORT="$CURRENT_VER"
  else
    CURRENT_SHORT=${NODE_VERSION[$CURRENT]}
  fi

  if [[ "$CURRENT" != "START" && "$CURRENT_SHORT" == "$TARGET_VER" ]]; then
    FOUND_PATH=true
    FOUND_NODE=$CURRENT
    break
  fi

  for CANDIDATE in "${SORTED_ENTRY_IDS[@]}"; do
    if [[ -n "${VISITED[$CANDIDATE]:-}" ]]; then continue; fi

    IS_VALID_HOP=false
    
    # 1. Check Replaces
    CAND_REPLACES=${NODE_REPLACES[$CANDIDATE]}
    if [[ -n "$CAND_REPLACES" ]]; then
      CAND_REPLACES_SHORT=$(short_ver_from_bundle "$CAND_REPLACES")
      if [[ "$CAND_REPLACES_SHORT" == "$CURRENT_SHORT" ]]; then IS_VALID_HOP=true; fi
    fi

    # 2. Check SkipRange
    if [ "$IS_VALID_HOP" = false ]; then
       CAND_SKIP=${NODE_SKIPRANGE[$CANDIDATE]}
       if check_range "$CURRENT_SHORT" "$CAND_SKIP"; then IS_VALID_HOP=true; fi
    fi
    
    if [ "$IS_VALID_HOP" = true ]; then
       VISITED["$CANDIDATE"]=1
       PARENT["$CANDIDATE"]=$CURRENT
       QUEUE+=("$CANDIDATE")
    fi
  done
done

if [ "$FOUND_PATH" = false ]; then
  echo "❌ Fatal: No path found from $CURRENT_VER to $TARGET_VER"
  exit 1
fi

# ==============================================================================
# 4. OUTPUT
# ==============================================================================
FINAL_PATH=()
TRACE=$FOUND_NODE
LOOP_LIMIT=100
COUNT=0

while [[ "$TRACE" != "START" ]]; do
  FINAL_PATH+=("$TRACE")
  TRACE=${PARENT[$TRACE]}
  
  COUNT=$((COUNT+1))
  if [ $COUNT -gt $LOOP_LIMIT ]; then echo "Error: Path loop."; exit 1; fi
done

echo ""
echo "## Shortest valid hop path"
echo "----------------------------------------------------"
PATH_SEGMENTS=()
for (( i=${#FINAL_PATH[@]}-1; i>=0; i-- )); do
  v=${NODE_VERSION[${FINAL_PATH[$i]}]}
  c=${NODE_CHANNEL[${FINAL_PATH[$i]}]}
  PATH_SEGMENTS+=("${v} (${c})")
done
PATH_STRING=""
for SEGMENT in "${PATH_SEGMENTS[@]}"; do
  if [[ -n "$PATH_STRING" ]]; then
    PATH_STRING+=" -> "
  fi
  PATH_STRING+="$SEGMENT"
done
printf '%s\n' "$PATH_STRING"
echo "----------------------------------------------------"
echo "## Generated ImageSetConfiguration"
echo "----------------------------------------------------"
if [[ $# -lt 5 ]]; then
  echo "# Catalog image defaulted to ${CATALOG_IMAGE}. Pass it as the 5th argument to avoid editing this field."
fi
echo "# Output uses minVersion only (floating heads). Add maxVersion if you want an exact pin."
echo "kind: ImageSetConfiguration"
echo "apiVersion: mirror.openshift.io/v2alpha1"
echo "mirror:"
echo "  operators:"
echo "    - catalog: $CATALOG_IMAGE"
echo "      packages:"
echo "        - name: $OPERATOR"
echo "          channels:"

LAST_CHANNEL=""
for (( i=${#FINAL_PATH[@]}-1; i>=0; i-- )); do
  ENTRY_ID=${FINAL_PATH[$i]}
  v=${NODE_VERSION[$ENTRY_ID]}
  REAL_CHANNEL=${NODE_CHANNEL[$ENTRY_ID]}

  if [[ "$REAL_CHANNEL" == "$LAST_CHANNEL" ]]; then
    continue
  fi

  echo "            - name: $REAL_CHANNEL"
  echo "              minVersion: $v"
  # maxVersion omitted deliberately to allow floating head (z-stream updates)
  LAST_CHANNEL=$REAL_CHANNEL
done
echo "----------------------------------------------------"
