#!/usr/bin/env bash
set -euo pipefail

MODS_JSON="${1:-mods.json}"

if ! command -v packwiz >/dev/null 2>&1; then
  echo "❌ packwiz not found in PATH"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq not found in PATH"
  exit 1
fi

if [[ ! -f "$MODS_JSON" ]]; then
  echo "❌ File not found: $MODS_JSON"
  exit 1
fi

INSTALLED=()
FAILED=()
SKIPPED=()
SIDE_UPDATED=()

get_side() {
  local client="$1"
  local server="$2"

  if [[ "$client" == "true" && "$server" == "true" ]]; then
    echo "both"
  elif [[ "$client" == "true" && "$server" == "false" ]]; then
    echo "client"
  elif [[ "$client" == "false" && "$server" == "true" ]]; then
    echo "server"
  else
    echo "invalid"
  fi
}

set_packwiz_side() {
  local file="$1"
  local side="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  if grep -q '^side = ' "$file"; then
    sed -i "s/^side = .*/side = \"$side\"/" "$file"
  else
    tmp="$(mktemp)"
    {
      echo "side = \"$side\""
      cat "$file"
    } > "$tmp"
    mv "$tmp" "$file"
  fi
}

find_mod_file() {
  local slug="$1"

  if [[ -f "mods/${slug}.pw.toml" ]]; then
    echo "mods/${slug}.pw.toml"
    return 0
  fi

  local found
  found="$(find mods -type f -name "*.pw.toml" 2>/dev/null | grep -i "/${slug}.pw.toml$" | head -n 1 || true)"

  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  found="$(grep -ril "$slug" mods/*.pw.toml 2>/dev/null | head -n 1 || true)"

  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

install_mod() {
  local source="$1"
  local slug="$2"

  echo "▶️ Installing $source:$slug"

  if [[ "$source" == "modrinth" ]]; then
    yes y | packwiz modrinth install "$slug" -y
  elif [[ "$source" == "curseforge" ]]; then
    yes y | packwiz curseforge install "$slug" -y
  else
    return 1
  fi
}

echo "📄 Reading mods from: $MODS_JSON"

count="$(jq '.mods | length' "$MODS_JSON")"

for i in $(seq 0 $((count - 1))); do
  url="$(jq -r ".mods[$i].url" "$MODS_JSON")"
  client="$(jq -r ".mods[$i].client // true" "$MODS_JSON")"
  server="$(jq -r ".mods[$i].server // true" "$MODS_JSON")"

  side="$(get_side "$client" "$server")"

  echo ""
  echo "========================================"
  echo "🔎 Processing: $url"
  echo "🧭 client=$client server=$server side=$side"

  if [[ "$side" == "invalid" ]]; then
    echo "⚠️ Invalid side config, skipped"
    SKIPPED+=("$url | invalid side config")
    continue
  fi

  source=""
  slug=""

  if [[ "$url" =~ modrinth\.com/mod/([^/?#]+) ]]; then
    source="modrinth"
    slug="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ curseforge\.com/minecraft/mc-mods/([^/?#]+) ]]; then
    source="curseforge"
    slug="${BASH_REMATCH[1]}"
  else
    echo "⚠️ Unknown link format, skipped"
    SKIPPED+=("$url | unknown link format")
    continue
  fi

  if install_mod "$source" "$slug"; then
    INSTALLED+=("$source:$slug")

    mod_file="$(find_mod_file "$slug" || true)"

    if [[ -n "$mod_file" ]]; then
      set_packwiz_side "$mod_file" "$side"
      echo "✅ Side updated: $mod_file → $side"
      SIDE_UPDATED+=("$source:$slug → $side")
    else
      echo "⚠️ Installed but .pw.toml file not found for side update: $source:$slug"
      FAILED+=("$source:$slug | installed but side not updated")
    fi
  else
    echo "❌ Failed: $source:$slug"
    FAILED+=("$source:$slug")
  fi
done

echo ""
echo "🔄 Running packwiz refresh..."

if packwiz refresh; then
  REFRESH_STATUS="✅ packwiz refresh completed"
else
  REFRESH_STATUS="❌ packwiz refresh failed"
  FAILED+=("packwiz:refresh")
fi

echo ""
echo "========================================"
echo "📋 Modpack sync report"
echo "========================================"

echo ""
echo "✅ Installed / processed: ${#INSTALLED[@]}"
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  for item in "${INSTALLED[@]}"; do
    echo "  - $item"
  done
else
  echo "  none"
fi

echo ""
echo "🧭 Side updated: ${#SIDE_UPDATED[@]}"
if [[ ${#SIDE_UPDATED[@]} -gt 0 ]]; then
  for item in "${SIDE_UPDATED[@]}"; do
    echo "  - $item"
  done
else
  echo "  none"
fi

echo ""
echo "❌ Failed: ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  for item in "${FAILED[@]}"; do
    echo "  - $item"
  done
else
  echo "  none"
fi

echo ""
echo "⏭️ Skipped: ${#SKIPPED[@]}"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  for item in "${SKIPPED[@]}"; do
    echo "  - $item"
  done
else
  echo "  none"
fi

echo ""
echo "$REFRESH_STATUS"
echo "========================================"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "# 📋 Modpack sync report"
    echo ""
    echo "## ✅ Installed / processed: ${#INSTALLED[@]}"
    echo ""
    if [[ ${#INSTALLED[@]} -gt 0 ]]; then
      for item in "${INSTALLED[@]}"; do
        echo "- \`$item\`"
      done
    else
      echo "_none_"
    fi

    echo ""
    echo "## 🧭 Side updated: ${#SIDE_UPDATED[@]}"
    echo ""
    if [[ ${#SIDE_UPDATED[@]} -gt 0 ]]; then
      for item in "${SIDE_UPDATED[@]}"; do
        echo "- \`$item\`"
      done
    else
      echo "_none_"
    fi

    echo ""
    echo "## ❌ Failed: ${#FAILED[@]}"
    echo ""
    if [[ ${#FAILED[@]} -gt 0 ]]; then
      for item in "${FAILED[@]}"; do
        echo "- \`$item\`"
      done
    else
      echo "_none_"
    fi

    echo ""
    echo "## ⏭️ Skipped: ${#SKIPPED[@]}"
    echo ""
    if [[ ${#SKIPPED[@]} -gt 0 ]]; then
      for item in "${SKIPPED[@]}"; do
        echo "- \`$item\`"
      done
    else
      echo "_none_"
    fi

    echo ""
    echo "## Refresh"
    echo ""
    echo "$REFRESH_STATUS"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  exit 1
fi