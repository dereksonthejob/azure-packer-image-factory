#!/usr/bin/env bash
# generate-patch-report.sh — parses packerbuild.log → structured markdown patch report
# Format matches: pre-update table (KB|Type|Date), Pass N sections (KB|Description|Size|Date)
# Critical rows (CU / SQL Server updates) are bolded.
set -euo pipefail

PROFILE_ID="${1:-unknown}"
LOG="${2:-packerbuild.log}"
OUT_DIR="patch-report"
OUT="$OUT_DIR/patch-report.md"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

mkdir -p "$OUT_DIR"

# Strip packer log prefix: "==> azure-arm.image: " or "    azure-arm.image: "
strip_prefix() { sed 's/^[= >]*[a-zA-Z0-9._-]*: //' ; }

# ── Extract source image metadata ─────────────────────────────────────────────
PUBLISHER=$(grep -m1 "Publisher :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs)
OFFER=$(grep -m1 "Offer     :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs)
SKU=$(grep -m1 "SKU       :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs)
VERSION=$(grep -m1 "Version   :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | xargs)
MS_PATCH=$(grep -m1 "MS Patch  :" "$LOG" | strip_prefix | awk -F': ' '{print $2}' | awk '{print $1}' | xargs)

# ── Extract pre-update hotfix list ────────────────────────────────────────────
# Format in log: "KB5050008 Security Update 1/9/2025 12:00:00 AM"
mapfile -t PRE_HOTFIXES < <(
  awk '/=== PRE-UPDATE HOTFIX BASELINE/,/Total pre-update patches/' "$LOG" \
  | grep -E "KB[0-9]+" \
  | strip_prefix \
  | grep -v "^HotFixID" \
  | sed 's/  */ /g'
)

# ── Extract windows-update provisioner passes ──────────────────────────────────
# Each "Found Windows update (DATE; SIZE): DESC (KB...)" line
# Passes are separated by "Windows update installation completed" or "No Windows updates found"
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
PASS1_META=$(grep -m1 "Downloading Windows updates" "$LOG" | strip_prefix | grep -oP '\(\K[^)]+' || echo "")
PASS1_COUNT=$(echo "$PASS1_META" | grep -oP '^\d+' || echo "${#PASS1_LINES[@]}")
PASS1_SIZE=$(echo "$PASS1_META" | grep -oP '[\d.]+ [MG]B$' | head -1 || echo "")
# Convert MB to GB if > 1024
if echo "$PASS1_SIZE" | grep -q "MB"; then
  MB=$(echo "$PASS1_SIZE" | grep -oP '[\d.]+')
  GB=$(echo "scale=1; $MB/1024" | bc 2>/dev/null || echo "")
  [ -n "$GB" ] && [ "$(echo "$GB > 1" | bc 2>/dev/null)" = "1" ] && PASS1_SIZE="~${GB} GB"
fi

# ── Format a single update line ───────────────────────────────────────────────
# Input: "Found Windows update (2026-03-10; 542.8 MB): Security Update for SQL (KB5077471)"
format_update_row() {
  local line="$1"
  # Extract date, size, description, KB
  local date size desc kb bold=""
  date=$(echo "$line" | grep -oP '\(\K[\d-]+(?=;)' || echo "—")
  size=$(echo "$line" | grep -oP '(?<=; )[\d.]+ [MGB]+(?=\))' || echo "—")
  desc=$(echo "$line" | sed 's/Found Windows update ([^)]*): //' | sed 's/ (KB[0-9]*)//')
  kb=$(echo "$line" | grep -oP 'KB[0-9]+' | tail -1 || echo "—")

  # Format date as "Mon YYYY" or "Mon DD, YYYY"
  if [[ "$date" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    local yr="${BASH_REMATCH[1]}" mo="${BASH_REMATCH[2]}"
    local months=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    date="${months[$((10#$mo-1))]} ${yr}"
  fi

  # Bold critical updates: CU, SQL Server, Malicious Software
  if echo "$desc" | grep -qiE "cumulative update|sql server|malicious software|security update for sql"; then
    bold="**"
  fi

  echo "| ${bold}${kb}${bold} | ${bold}${desc}${bold} | ${bold}${size}${bold} | ${bold}${date}${bold} |"
}

# Format pre-update hotfix date
format_hf_date() {
  local raw="$1"
  # Input like "1/9/2025 12:00:00 AM" → "Jan 9, 2025"
  local m d y
  m=$(echo "$raw" | cut -d'/' -f1)
  d=$(echo "$raw" | cut -d'/' -f2)
  y=$(echo "$raw" | cut -d'/' -f3 | awk '{print $1}')
  local months=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  echo "${months[$((m-1))]} $d, $y"
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
  for hf in "${PRE_HOTFIXES[@]}"; do
    kb=$(echo "$hf" | awk '{print $1}')
    type=$(echo "$hf" | awk '{print $2, $3}' | xargs)
    date_raw=$(echo "$hf" | awk '{print $4}')
    date_fmt=$(format_hf_date "$date_raw")
    echo "| $kb | $type | $date_fmt |"
  done
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
