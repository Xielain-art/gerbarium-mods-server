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

if ! command -v curl >/dev/null 2>&1; then
  echo "❌ curl not found in PATH"
  exit 1
fi

if [[ ! -f "$MODS_JSON" ]]; then
  echo "❌ File not found: $MODS_JSON"
  exit 1
fi

mkdir -p mods

INSTALLED=()
SIDE_UPDATED=()
REMOVED=()
FAILED=()
SKIPPED=()

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

extract_slug_from_url() {
  local url="$1"

  if [[ "$url" =~ modrinth\.com/mod/([^/?#]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  elif [[ "$url" =~ curseforge\.com/minecraft/mc-mods/([^/?#]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

extract_source_from_url() {
  local url="$1"

  if [[ "$url" =~ modrinth\.com/mod/([^/?#]+) ]]; then
    echo "modrinth"
    return 0
  elif [[ "$url" =~ curseforge\.com/minecraft/mc-mods/([^/?#]+) ]]; then
    echo "curseforge"
    return 0
  fi

  return 1
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
    local tmp
    tmp="$(mktemp)"
    {
      echo "side = \"$side\""
      cat "$file"
    } > "$tmp"
    mv "$tmp" "$file"
  fi
}

find_mod_file_by_filename() {
  local filename="$1"

  if [[ -z "$filename" ]]; then
    return 1
  fi

  grep -Rsl "filename = \"$filename\"" mods/*.pw.toml 2>/dev/null | head -n 1
}

find_mod_file_by_modrinth_slug() {
  local slug="$1"

  local project_id
  project_id="$(
    curl -fsSL "https://api.modrinth.com/v2/project/$slug" 2>/dev/null \
      | jq -r '.id // empty' || true
  )"

  if [[ -z "$project_id" ]]; then
    return 1
  fi

  grep -Rsl "mod-id = \"$project_id\"" mods/*.pw.toml 2>/dev/null | head -n 1
}

find_mod_file_by_slug_fallback() {
  local slug="$1"

  if [[ -f "mods/${slug}.pw.toml" ]]; then
    echo "mods/${slug}.pw.toml"
    return 0
  fi

  find mods -type f -name "*.pw.toml" 2>/dev/null \
    | grep -i "/${slug}.pw.toml$" \
    | head -n 1 || true
}

find_mod_file_for_url() {
  local url="$1"
  local source
  local slug

  source="$(extract_source_from_url "$url" || true)"
  slug="$(extract_slug_from_url "$url" || true)"

  if [[ -z "$source" || -z "$slug" ]]; then
    return 1
  fi

  local mod_file=""

  if [[ "$source" == "modrinth" ]]; then
    mod_file="$(find_mod_file_by_modrinth_slug "$slug" || true)"
  fi

  if [[ -z "$mod_file" ]]; then
    mod_file="$(find_mod_file_by_slug_fallback "$slug" || true)"
  fi

  if [[ -n "$mod_file" ]]; then
    echo "$mod_file"
    return 0
  fi

  return 1
}

extract_project_filename_from_output() {
  local output_file="$1"

  grep -E 'Project ".+" successfully added! \(.+\.jar\)' "$output_file" \
    | tail -n 1 \
    | sed -E 's/.*\(([^()]+\.jar)\).*/\1/' || true
}

install_mod() {
  local source="$1"
  local slug="$2"
  local output_file="$3"

  echo "▶️ Installing $source:$slug"

  if [[ "$source" == "modrinth" ]]; then
    packwiz modrinth install "$slug" -y > "$output_file" 2>&1
  elif [[ "$source" == "curseforge" ]]; then
    packwiz curseforge install "$slug" -y > "$output_file" 2>&1
  else
    return 1
  fi
}

remove_deleted_mods_from_previous_json() {
  local current_json="$1"

  if ! git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    echo "ℹ️ No previous commit found, skip deleted mods check"
    return 0
  fi

  if ! git show HEAD^:"$current_json" >/tmp/previous-mods.json 2>/dev/null; then
    echo "ℹ️ Previous $current_json not found, skip deleted mods check"
    return 0
  fi

  jq -r '.mods[].url' /tmp/previous-mods.json | sort -u > /tmp/previous-urls.txt
  jq -r '.mods[].url' "$current_json" | sort -u > /tmp/current-urls.txt

  comm -23 /tmp/previous-urls.txt /tmp/current-urls.txt > /tmp/deleted-urls.txt

  if [[ ! -s /tmp/deleted-urls.txt ]]; then
    echo "ℹ️ No deleted mods detected"
    return 0
  fi

  echo ""
  echo "🗑️ Deleted mods detected"

  while IFS= read -r deleted_url || [[ -n "$deleted_url" ]]; do
    [[ -z "$deleted_url" ]] && continue

    echo "🗑️ Removing deleted mod from JSON: $deleted_url"

    local slug
    slug="$(extract_slug_from_url "$deleted_url" || true)"

    if [[ -z "$slug" ]]; then
      echo "⚠️ Cannot extract slug from deleted URL: $deleted_url"
      SKIPPED+=("$deleted_url | deleted but slug not detected")
      continue
    fi

    local mod_file
    mod_file="$(find_mod_file_for_url "$deleted_url" || true)"

    if [[ -n "$mod_file" && -f "$mod_file" ]]; then
      rm -f "$mod_file"
      echo "✅ Removed file: $mod_file"
      REMOVED+=("$slug")
    else
      echo "⚠️ File not found for deleted mod: $slug"
      SKIPPED+=("$slug | deleted but file not found")
    fi
  done < /tmp/deleted-urls.txt
}

echo "📄 Reading mods from: $MODS_JSON"

remove_deleted_mods_from_previous_json "$MODS_JSON"

count="$(jq '.mods | length' "$MODS_JSON")"

for i in $(seq 0 $((count - 1))); do
  url="$(jq -r ".mods[$i].url" "$MODS_JSON")"
  client="$(jq -r ".mods[$i].client // true" "$MODS_JSON")"
  server="$(jq -r ".mods[$i].server // true" "$MODS_JSON")"
  enabled="$(jq -r ".mods[$i].enabled // true" "$MODS_JSON")"

  echo ""
  echo "========================================"
  echo "🔎 Processing: $url"

  if [[ "$enabled" != "true" ]]; then
    echo "⏭️ Disabled, skipped"
    SKIPPED+=("$url | disabled")
    continue
  fi

  side="$(get_side "$client" "$server")"

  echo "🧭 client=$client server=$server side=$side"

  if [[ "$side" == "invalid" ]]; then
    echo "⚠️ Invalid side config, skipped"
    SKIPPED+=("$url | invalid side config")
    continue
  fi

  source="$(extract_source_from_url "$url" || true)"
  slug="$(extract_slug_from_url "$url" || true)"

  if [[ -z "$source" || -z "$slug" ]]; then
    echo "⚠️ Unknown link format, skipped"
    SKIPPED+=("$url | unknown link format")
    continue
  fi

  output_file="$(mktemp)"

  if install_mod "$source" "$slug" "$output_file"; then
    cat "$output_file"

    echo "✅ Install command success: $source:$slug"
    INSTALLED+=("$source:$slug")
  else
    cat "$output_file"

    echo "❌ Install command failed: $source:$slug"
    FAILED+=("$source:$slug | install failed")
    rm -f "$output_file"
    continue
  fi

  filename="$(extract_project_filename_from_output "$output_file")"
  rm -f "$output_file"

  mod_file=""

  if [[ -n "$filename" ]]; then
    mod_file="$(find_mod_file_by_filename "$filename" || true)"
  fi

  if [[ -z "$mod_file" && "$source" == "modrinth" ]]; then
    mod_file="$(find_mod_file_by_modrinth_slug "$slug" || true)"
  fi

  if [[ -z "$mod_file" ]]; then
    mod_file="$(find_mod_file_by_slug_fallback "$slug" || true)"
  fi

  if [[ -n "$mod_file" ]]; then
    set_packwiz_side "$mod_file" "$side"
    echo "✅ Side updated: $mod_file → $side"
    SIDE_UPDATED+=("$source:$slug → $side")
  else
    echo "⚠️ Installed, but .pw.toml file not found for side update: $source:$slug"
    FAILED+=("$source:$slug | side not updated")
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
echo "🗑️ Removed: ${#REMOVED[@]}"
if [[ ${#REMOVED[@]} -gt 0 ]]; then
  for item in "${REMOVED[@]}"; do
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
    echo "## 🗑️ Removed: ${#REMOVED[@]}"
    echo ""
    if [[ ${#REMOVED[@]} -gt 0 ]]; then
      for item in "${REMOVED[@]}"; do
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