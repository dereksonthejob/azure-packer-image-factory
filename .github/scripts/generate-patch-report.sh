#!/usr/bin/env bash
# generate-patch-report.sh — parses packerbuild.log → structured markdown patch report
# Format matches: pre-update table (KB|Type|Date), Pass N sections (KB|Description|Size|Date)
# Critical rows (CU / SQL Server updates) are bolded.
#
# NOTE: -u (nounset) is intentionally omitted. Bash arrays with negative indices
# (e.g. ${months[-1]}) trigger "unbound variable" under set -u even though the
# array itself is defined. Guards are used instead where empty values are possible.
set -eo pipefail

PROFILE_ID="${1:-unknown}"
LOG="${2:-packerbuild.log}"
OUT_DIR="patch-report"
OUT="$OUT_DIR/patch-report.md"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

mkdir -p "$OUT_DIR"

# Bail gracefully if the log is missing (pre-flight failures etc.)
if [[ ! -f "$LOG" ]]; then
  echo "::warning ::generate-patch-report: '$LOG' not found — skipping report generation."
  exit 0
fi

# Strip packer log prefix: "==> azure-arm.image: " or "    azure-arm.image: "
strip_prefix() { sed 's/^[= >]*[a-zA-Z0-9._-]*: //' ; }

# ── Extract source image metadata ─────────────────────────────────────────────
PUBLISHER=$(grep -m1 "Publisher :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs || true)
OFFER=$(grep -m1 "Offer     :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs || true)
SKU=$(grep -m1 "SKU       :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs || true)
VERSION=$(grep -m1 "Version   :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs || true)
MS_PATCH=$(grep -m1 "MS Patch  :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | awk '{print $1}' | xargs || true)

# ── Extract pre-update hotfix list ────────────────────────────────────────────
# Log format per line: "KB5050008 Security Update 1/9/2025 12:00:00 AM"
# The type field may be 1 word ("Update") or 2+ words ("Security Update").
# We extract the KB, type (everything between KB and the date), and date separately.
mapfile -t PRE_HOTFIXES < <(
  awk '/=== PRE-UPDATE HOTFIX BASELINE/,/Total pre-update patches/' "$LOG" \
  | grep -E "KB[0-9]+" \
  | strip_prefix \
  | grep -v "^HotFixID" \
  | sed 's/  */ /g'
)

# ── Extract windows-update provisioner passes ──────────────────────────────────
PASS=0
declare -a PASS1_LINES PASS2_LINES
IN_WU=false

while IFS= read -r line; do
  clean=$(echo "$line" | strip_prefix)
  if echo "$clean" | grep -q "Running Windows update\.\.\." 2>/dev/null; then
    IN_WU=true
    PASS=$((PASS+1))
  fi
  if $IN_WU && echo "$clean" | grep -qE "^Found Windows update"; then
    if [ "$PASS" -eq 1 ]; then
      PASS1_LINES+=("$clean")
    elif [ "$PASS" -eq 2 ]; then
      PASS2_LINES+=("$clean")
    fi
  fi
  if echo "$clean" | grep -qE "installation completed|No Windows updates found"; then
    IN_WU=false
  fi
done < "$LOG"

# Extract total size/count from "Downloading Windows updates (N updates; X MB)..."
PASS1_META=$(grep -m1 "Downloading Windows updates" "$LOG" | strip_prefix \
  | awk -F'[()]' '{print $2}' || true)
PASS1_COUNT=$(echo "$PASS1_META" | awk -F' updates' '{print $1}' | tr -cd '0-9' || echo "${#PASS1_LINES[@]}")
PASS1_SIZE=$(echo "$PASS1_META" | awk -F'; ' '{print $2}' | sed 's/)//g' | xargs || true)
# Convert MB to GB if > 1024
if echo "$PASS1_SIZE" | grep -q "MB"; then
  MB=$(echo "$PASS1_SIZE" | sed 's/ MB//' | tr -cd '0-9.')
  GB=$(echo "scale=1; $MB/1024" | bc 2>/dev/null || true)
  [ -n "$GB" ] && [ "$(echo "$GB > 1" | bc 2>/dev/null || echo 0)" = "1" ] && PASS1_SIZE="~${GB} GB"
fi

# ── Format a single update line ───────────────────────────────────────────────
# Input: "Found Windows update (2026-03-10; 542.8 MB): Security Update for SQL (KB5077471)"
format_update_row() {
  local line="$1"
  local date size desc kb bold=""

  # Use awk to extract the parenthesised metadata block: "(2026-03-10; 542.8 MB)"
  date=$(echo "$line" | awk -F'[();]' '{print $2}' | xargs || echo "—")
  size=$(echo "$line" | awk -F'[();]' '{print $3}' | xargs || echo "—")
  desc=$(echo "$line" | sed 's/Found Windows update ([^)]*): //' | sed 's/ (KB[0-9]*)//' | xargs)
  kb=$(echo "$line"   | awk 'match($0, /KB[0-9]+/) {print substr($0, RSTART, RLENGTH)}' | tail -1)
  kb="${kb:----}"

  # Format date as "Mon YYYY" (input: YYYY-MM-DD)
  if [[ "$date" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    local yr="${BASH_REMATCH[1]}" mo="${BASH_REMATCH[2]}"
    local months=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    local mo_idx=$((10#$mo - 1))
    if (( mo_idx >= 0 && mo_idx <= 11 )); then
      date="${months[$mo_idx]} ${yr}"
    fi
  fi

  # Bold critical updates
  if echo "$desc" | grep -qiE "cumulative update|sql server|malicious software|security update for sql"; then
    bold="**"
  fi

  echo "| ${bold}${kb}${bold} | ${bold}${desc}${bold} | ${bold}${size}${bold} | ${bold}${date}${bold} |"
}

# ── Format pre-update hotfix row ───────────────────────────────────────────────
# Input line: "KB5050008 Security Update 1/9/2025 12:00:00 AM"
#             "KB5066139 Update          1/8/2026 12:00:00 AM"
# Strategy: KB=$1; find the first token matching M/D/YYYY with awk; type=everything between.
format_hf_row() {
  local hf="$1"
  local kb date_raw type date_fmt

  kb=$(echo "$hf" | awk '{print $1}')

  # Find the first field matching digit(s)/digit(s)/4-digits using awk (portable, no grep -P)
  date_raw=$(echo "$hf" | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /^[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{4}$/) { print $i; exit }
    }
  }')

  if [[ -n "$date_raw" ]]; then
    # Type = everything between KB and the date token
    type=$(echo "$hf" | sed "s/^${kb}[[:space:]]*//" | sed "s|[[:space:]]*${date_raw}.*||" | xargs)
  else
    type=$(echo "$hf" | awk '{$1=""; print}' | xargs)
    date_raw=""
  fi

  # Format M/D/YYYY → "Mon D, YYYY" using bash regex (no external tool needed)
  if [[ "$date_raw" =~ ^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$ ]]; then
    local m="${BASH_REMATCH[1]}" d="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}"
    local months=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    local m_idx=$((10#$m - 1))
    if (( m_idx >= 0 && m_idx <= 11 )); then
      date_fmt="${months[$m_idx]} $d, $y"
    else
      date_fmt="$date_raw"
    fi
  else
    date_fmt="${date_raw:----}"
  fi

  echo "| $kb | $type | $date_fmt |"
}

# ── Build the report ──────────────────────────────────────────────────────────
{
  echo "## Windows Updates Applied — \`${PROFILE_ID}\`"
  echo ""
  [ -n "$MS_PATCH" ] && echo "_Source image: **${PUBLISHER}** · **${OFFER}** · **${SKU}** · v${VERSION} · MS patch date: **${MS_PATCH}**_"
  echo ""

  # Pre-update section
  echo "**Pre-update state** (hotfixes already on the base image):"
  echo ""
  echo "| KB | Type | Date |"
  echo "|----|------|------|"
  if [ "${#PRE_HOTFIXES[@]}" -gt 0 ]; then
    for hf in "${PRE_HOTFIXES[@]}"; do
      format_hf_row "$hf"
    done
  else
    echo "| — | No hotfixes detected | — |"
  fi
  echo ""

  # Pass 1
  if [ "${#PASS1_LINES[@]}" -gt 0 ]; then
    size_note=""
    [ -n "$PASS1_SIZE" ] && size_note=" (~${PASS1_SIZE} total)"
    echo "**Pass 1 — ${PASS1_COUNT} updates downloaded and installed${size_note}:**"
    echo ""
    echo "| KB | Description | Size | Date |"
    echo "|----|-------------|------|------|"
    for line in "${PASS1_LINES[@]}"; do
      format_update_row "$line"
    done
    echo ""
  fi

  # Pass 2
  if [ "${#PASS2_LINES[@]}" -gt 0 ]; then
    echo "**Pass 2 — ${#PASS2_LINES[@]} additional update(s):**"
    echo ""
    echo "| KB | Description | Size | Date |"
    echo "|----|-------------|------|------|"
    for line in "${PASS2_LINES[@]}"; do
      format_update_row "$line"
    done
    echo ""
  else
    echo "**Pass 2** — _No additional updates found (fully patched after Pass 1 reboot)_ ✅"
    echo ""
  fi

  echo "---"
  echo "_Report generated: $(date -u '+%Y-%m-%d %H:%M UTC')_"

} | tee "$OUT" >> "$SUMMARY"

echo "Patch report written to $OUT"
