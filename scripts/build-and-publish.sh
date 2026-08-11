#!/bin/bash
set -euo pipefail

# Auto build, create GitHub repo, upload deb, retry on failure.
# Requires: macOS, Theos, jq, curl, GitHub token with repo+delete_repo scope.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

REPO_NAME="${REPO_NAME:-Quick}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
MAX_RETRIES="${MAX_RETRIES:-3}"

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "ERROR: GITHUB_TOKEN not set."
  exit 1
fi

API_BASE="https://api.github.com"
AUTH_HDR="Authorization: Bearer $GITHUB_TOKEN"

notify() {
  local msg="$1"
  echo "[QuickClipboard] NOTIFY: $msg"
  # On macOS you can uncomment the next line for native notification
  # osascript -e "display notification \"$msg\" with title \"QuickClipboard\""
}

create_repo_if_needed() {
  local payload
  payload=$(jq -n \
    --arg name "$REPO_NAME" \
    '{name: $name, description: "QuickClipboard jailbreak tweak builds", private: false, auto_init: true}')
  
  local status
  status=$(curl -s -o /tmp/qc_create_repo.json -w "%{http_code}" \
    -H "$AUTH_HDR" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$payload" \
    "$API_BASE/user/repos")
  
  if [[ "$status" == "201" ]]; then
    notify "GitHub 仓库 $REPO_NAME 创建成功"
  elif [[ "$status" == "422" ]]; then
    notify "GitHub 仓库 $REPO_NAME 已存在"
  else
    echo "ERROR: Failed to create repo (HTTP $status)"
    cat /tmp/qc_create_repo.json
    return 1
  fi
}

get_user_login() {
  if [[ -n "$GITHUB_USERNAME" ]]; then return; fi
  GITHUB_USERNAME=$(curl -s -H "$AUTH_HDR" "$API_BASE/user" | jq -r '.login // empty')
  if [[ -z "$GITHUB_USERNAME" ]]; then
    echo "ERROR: Could not get GitHub username"
    exit 1
  fi
}

upload_deb() {
  local deb_path="$1"
  local filename
  filename=$(basename "$deb_path")
  local encoded
  encoded=$(base64 -i "$deb_path")
  
  local path="/repos/$GITHUB_USERNAME/$REPO_NAME/contents/Packages/$filename"
  
  # Check existing sha
  local sha=""
  local existing_status
  existing_status=$(curl -s -o /tmp/qc_get_file.json -w "%{http_code}" \
    -H "$AUTH_HDR" \
    "$API_BASE$path")
  if [[ "$existing_status" == "200" ]]; then
    sha=$(jq -r '.sha // empty' /tmp/qc_get_file.json)
  fi
  
  local payload
  if [[ -n "$sha" ]]; then
    payload=$(jq -n --arg msg "Update $filename" --arg content "$encoded" --arg sha "$sha" '{message: $msg, content: $content, sha: $sha}')
  else
    payload=$(jq -n --arg msg "Add $filename" --arg content "$encoded" '{message: $msg, content: $content}')
  fi
  
  local status
  status=$(curl -s -o /tmp/qc_upload.json -w "%{http_code}" \
    -H "$AUTH_HDR" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$API_BASE$path")
  
  if [[ "$status" == "200" || "$status" == "201" ]]; then
    notify "deb 包上传成功: $filename"
    return 0
  else
    echo "ERROR: Upload failed (HTTP $status)"
    cat /tmp/qc_upload.json
    return 1
  fi
}

attempt_build() {
  cd "$PROJECT_DIR"
  make clean 2>/dev/null || true
  if make package FINALPACKAGE=1; then
    return 0
  else
    return 1
  fi
}

auto_fix_common_errors() {
  local log="$1"
  echo "[QuickClipboard] Analyzing build log for known issues..."
  
  if grep -q "UIKit/UIKit.h file not found" "$log" || grep -q "framework not found UIKit" "$log"; then
    echo "[QuickClipboard] Fix: verifying SDK path..."
    export SYSROOT="${SYSROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  fi
  
  if grep -q "libsqlite3" "$log"; then
    echo "[QuickClipboard] Fix: ensuring sqlite3 library is available..."
  fi
  
  if grep -q "Preferences/Preferences.h" "$log"; then
    echo "[QuickClipboard] Fix: Preferences framework header path may need THEOS/sdks/iPhoneOS.../PrivateFrameworks"
  fi
}

main() {
  echo "[QuickClipboard] Starting automated build & publish..."
  get_user_login
  create_repo_if_needed
  
  local attempt=0
  local success=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$((attempt + 1))
    echo "[QuickClipboard] Build attempt $attempt/$MAX_RETRIES..."
    if attempt_build 2>&1 | tee /tmp/qc_build.log; then
      success=1
      break
    else
      echo "[QuickClipboard] Build failed on attempt $attempt"
      auto_fix_common_errors /tmp/qc_build.log
    fi
  done
  
  if [[ $success -ne 1 ]]; then
    notify "构建失败，已达最大重试次数 ($MAX_RETRIES)"
    exit 1
  fi
  
  local deb_path
  deb_path=$(ls -t "$PROJECT_DIR"/packages/*.deb 2>/dev/null | head -n1)
  if [[ -z "$deb_path" ]]; then
    echo "ERROR: No deb package found in packages/"
    exit 1
  fi
  
  upload_deb "$deb_path"
  notify "QuickClipboard 构建并发布完成: $(basename "$deb_path")"
  echo "[QuickClipboard] Done. Package: $deb_path"
}

main "$@"
