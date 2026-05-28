#!/usr/bin/env bash
# preflight.sh — verify the host has everything needed before running
# sfdx-local-test-install.sh. Exits non-zero if any required check fails.
#
# Usage:
#   bash preflight.sh           # interactive output, exits 1 on failure
#   bash preflight.sh --quiet   # only print failures
#   bash preflight.sh --json    # machine-readable; non-zero exit on failure

set -uo pipefail

QUIET=false
JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --json)  JSON=true; shift ;;
    -h|--help)
      cat <<USAGE
preflight.sh — checks for sfdx-local-test-install.sh

  --quiet   only print failures
  --json    machine-readable output
  -h        this help
USAGE
      exit 0 ;;
    *) shift ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

CHECK_NAMES=(); CHECK_STATUSES=(); CHECK_DETAILS=(); CHECK_FIXES=()

record() {
  local name="$1" status="$2" detail="${3:-}" fix="${4:-}"
  CHECK_NAMES+=("$name")
  CHECK_STATUSES+=("$status")
  CHECK_DETAILS+=("$detail")
  CHECK_FIXES+=("$fix")
}

# ── Required commands ────────────────────────────────────────────────────────
for cmd in gh git node npm sf code python3 zip unzip; do
  if command -v "$cmd" >/dev/null 2>&1; then
    record "$cmd" pass "$($cmd --version 2>&1 | head -1 | tr -d '\n' | head -c 80)"
  else
    case "$cmd" in
      gh)     fix="brew install gh && gh auth login" ;;
      git)    fix="brew install git" ;;
      node)   fix="brew install node@22 (or use volta/nvm)" ;;
      npm)    fix="comes with node" ;;
      sf)     fix="npm install -g @salesforce/cli" ;;
      code)   fix="install VS Code, then 'Shell Command: Install code in PATH' from cmd palette" ;;
      python3) fix="brew install python" ;;
      zip|unzip) fix="builtin on macOS — should not be missing" ;;
    esac
    record "$cmd" fail "not found in PATH" "$fix"
  fi
done

# ── Node major version ───────────────────────────────────────────────────────
if command -v node >/dev/null; then
  ver=$(node --version 2>/dev/null | sed 's/^v//')
  major=${ver%%.*}
  if [[ -n "$major" && "$major" -ge 22 ]]; then
    record "node>=22" pass "$ver"
  else
    record "node>=22" fail "got $ver" "use node 22 or 24 (volta/nvm)"
  fi
fi

# ── gh logged in (at least one account) ──────────────────────────────────────
if command -v gh >/dev/null; then
  if gh auth status >/dev/null 2>&1; then
    accounts=$(gh auth status 2>&1 | awk '/Logged in to github.com account/ { for(i=1;i<=NF;i++) if($i=="account") print $(i+1) }' | tr '\n' ' ')
    record "gh auth" pass "logged in: ${accounts}"
  else
    record "gh auth" fail "no accounts logged in" "gh auth login"
  fi
fi

# ── gh access to required repos (one probe per owner) ────────────────────────
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  declare -a OWNERS=( "forcedotcom" "salesforcecli" "salesforce-experience-platform-emu" "salesforce-internal" )
  active="$(gh auth status 2>&1 | awk '/Logged in to github.com account/{last=$NF; for(i=1;i<=NF;i++) if($i=="account") last=$(i+1)} /Active account: true/{print last; exit}')"
  for owner in "${OWNERS[@]}"; do
    found=false
    while IFS= read -r acc; do
      [[ -z "$acc" ]] && continue
      if gh auth switch --user "$acc" >/dev/null 2>&1; then
        if gh api "users/$owner" --silent >/dev/null 2>&1 && \
           ( gh api "orgs/$owner/repos?per_page=1" --silent >/dev/null 2>&1 \
             || gh api "users/$owner/repos?per_page=1" --silent >/dev/null 2>&1 ); then
          record "gh access: $owner" pass "via $acc"
          found=true; break
        fi
      fi
    done < <(gh auth status 2>&1 | awk '/Logged in to github.com account/ { for(i=1;i<=NF;i++) if($i=="account") print $(i+1) }')
    if ! $found; then
      case "$owner" in
        forcedotcom|salesforcecli)
          record "gh access: $owner" fail "no logged-in account has access" "gh auth login (any github account)" ;;
        *)
          record "gh access: $owner" warn "no access — internal-only repos will be skipped" "gh auth login --hostname github.com (with your @salesforce.com account)" ;;
      esac
    fi
  done
  # Restore active
  [[ -n "$active" ]] && gh auth switch --user "$active" >/dev/null 2>&1 || true
fi

# ── Disk space (~30 GB free recommended) ─────────────────────────────────────
if command -v df >/dev/null; then
  free_gb=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$free_gb" && "$free_gb" -ge 30 ]]; then
    record "disk space" pass "${free_gb}G free in \$HOME"
  elif [[ -n "$free_gb" && "$free_gb" -ge 15 ]]; then
    record "disk space" warn "${free_gb}G free (recommend 30G+, the workdir is ~10G of clones+node_modules)"
  else
    record "disk space" fail "only ${free_gb:-?}G free" "free up at least 15G"
  fi
fi

# ── VS Code accessible ───────────────────────────────────────────────────────
if command -v code >/dev/null; then
  case "$(uname -s)" in
    Darwin) code_user_dir="$HOME/Library/Application Support/Code/User" ;;
    Linux)  code_user_dir="$HOME/.config/Code/User" ;;
    *) code_user_dir="" ;;
  esac
  if [[ -n "$code_user_dir" && -d "$code_user_dir" ]]; then
    record "vscode user dir" pass "$code_user_dir"
  else
    record "vscode user dir" warn "expected at $code_user_dir — open VS Code at least once first" "open -a 'Visual Studio Code' (then close)"
  fi
fi

# ── Output ───────────────────────────────────────────────────────────────────
fails=0; warns=0
for s in "${CHECK_STATUSES[@]}"; do
  case "$s" in fail) ((fails++)) ;; warn) ((warns++)) ;; esac
done

if $JSON; then
  printf '{\n  "checks": [\n'
  for i in "${!CHECK_NAMES[@]}"; do
    [[ $i -gt 0 ]] && printf ',\n'
    printf '    {"name": %s, "status": "%s", "detail": %s, "fix": %s}' \
      "$(printf '%s' "${CHECK_NAMES[$i]}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
      "${CHECK_STATUSES[$i]}" \
      "$(printf '%s' "${CHECK_DETAILS[$i]}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "${CHECK_FIXES[$i]}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
  done
  printf '\n  ],\n  "fails": %d,\n  "warns": %d\n}\n' "$fails" "$warns"
else
  for i in "${!CHECK_NAMES[@]}"; do
    name="${CHECK_NAMES[$i]}"
    s="${CHECK_STATUSES[$i]}"
    d="${CHECK_DETAILS[$i]}"
    f="${CHECK_FIXES[$i]}"
    case "$s" in
      pass) $QUIET || printf "${GREEN}✓${NC} %-30s ${BLUE}%s${NC}\n" "$name" "$d" ;;
      warn) printf "${YELLOW}⚠${NC} %-30s %s\n" "$name" "$d"
            [[ -n "$f" ]] && printf "  fix: ${BLUE}%s${NC}\n" "$f" ;;
      fail) printf "${RED}✗${NC} %-30s ${RED}%s${NC}\n" "$name" "$d"
            [[ -n "$f" ]] && printf "  fix: ${BLUE}%s${NC}\n" "$f" ;;
    esac
  done
  echo
  if [[ $fails -gt 0 ]]; then
    echo -e "${RED}preflight failed:${NC} $fails error(s), $warns warning(s)"
  elif [[ $warns -gt 0 ]]; then
    echo -e "${YELLOW}preflight ok with warnings:${NC} $warns warning(s)"
  else
    echo -e "${GREEN}preflight ok:${NC} all checks passed"
  fi
fi

[[ $fails -gt 0 ]] && exit 1
exit 0
