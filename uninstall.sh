#!/usr/bin/env bash
# uninstall.sh — undo what sfdx-local-test-install.sh set up.
#
# Removes installed extensions, unlinks the sf plugin, deletes installed
# skills, removes the git url.insteadOf rewrite, and (optionally) wipes
# the workdir.
#
# Usage:
#   bash uninstall.sh                       # interactive — confirms each section
#   bash uninstall.sh -y                    # non-interactive, do everything
#   bash uninstall.sh --workdir DIR         # specify workdir to wipe (else asks)
#   bash uninstall.sh --keep-workdir        # don't wipe the workdir
#   bash uninstall.sh --only ext,plugin     # only run named sections
#                                             sections: ext, plugin, skills,
#                                                       insteadof, workdir

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*" >&2; }
info() { echo -e "${BLUE}   ·${NC} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
step() { echo -e "\n${GREEN}━━${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -f "$SCRIPT_DIR/repos.conf" ]] && source "$SCRIPT_DIR/repos.conf"

YES=false
WORKDIR=""
KEEP_WORKDIR=false
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        YES=true; shift ;;
    --workdir)       WORKDIR="$2"; shift 2 ;;
    --keep-workdir)  KEEP_WORKDIR=true; shift ;;
    --only)          ONLY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "Unknown arg: $1"; exit 1 ;;
  esac
done

want() {
  [[ -z "$ONLY" ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]]
}

confirm() {
  $YES && return 0
  read -r -p "$1 [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── 1. Uninstall salesforcedx-vscode-* + einstein-gpt extensions ─────────────
if want ext; then
  step "Section 1: uninstall locally-installed extensions"
  EXT_LIST=$(code --list-extensions 2>/dev/null | grep -E '^salesforce\.salesforcedx-(vscode|einstein-gpt)' || true)
  if [[ -z "$EXT_LIST" ]]; then
    info "No matching extensions installed."
  else
    echo "$EXT_LIST" >&2
    if confirm "Uninstall these ${$(echo "$EXT_LIST" | wc -l | tr -d ' ')} extensions?"; then
      while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        code --uninstall-extension "$ext" 2>&1 | tail -1
      done <<< "$EXT_LIST"
    fi
  fi
fi

# ── 2. Unlink the sf templates plugin ────────────────────────────────────────
if want plugin; then
  step "Section 2: unlink sf plugin-templates"
  if sf plugins 2>/dev/null | grep -q '@salesforce/plugin-templates\|^templates'; then
    if confirm "Run 'sf plugins unlink @salesforce/plugin-templates'?"; then
      sf plugins unlink @salesforce/plugin-templates 2>&1 | tail -3
    fi
  else
    info "plugin-templates is not currently linked."
  fi
fi

# ── 3. Remove installed AFV skills + clear globalSkillsToggles ───────────────
if want skills; then
  step "Section 3: remove installed AFV skills + clear toggles"
  case "$(uname -s)" in
    Darwin) EINSTEIN_DIR="$HOME/Library/Application Support/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
            VSCDB="$HOME/Library/Application Support/Code/User/globalStorage/state.vscdb" ;;
    Linux)  EINSTEIN_DIR="$HOME/.config/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
            VSCDB="$HOME/.config/Code/User/globalStorage/state.vscdb" ;;
    *) warn "Unsupported OS — skipping"; EINSTEIN_DIR="" ;;
  esac
  if [[ -n "$EINSTEIN_DIR" ]]; then
    SKILLS_DIR="$EINSTEIN_DIR/Skills"
    if [[ -d "$SKILLS_DIR" ]]; then
      count=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
      if (( count > 0 )); then
        info "Found $count skill(s) in $SKILLS_DIR"
        if confirm "Delete all $count skill(s) from Skills/ ?"; then
          find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -exec /bin/rm -rf {} +
          log "Removed $count skill(s) from Skills/"
        fi
      fi
    fi
    # Force the extension to re-seed Skills-Salesforce/ on next launch by
    # bumping (well, deleting) version.json so the seed thinks the disk is
    # stale. This re-copies the bundled skills back, undoing the deletes
    # the install script did.
    SF_DIR="$EINSTEIN_DIR/Skills-Salesforce"
    if [[ -d "$SF_DIR" ]]; then
      if confirm "Force AFV to re-seed Skills-Salesforce/ on next launch (restores official skills)?"; then
        /bin/rm -f "$SF_DIR/version.json"
        log "Removed $SF_DIR/version.json — extension will re-copy bundled skills on next reload"
      fi
    fi
  fi
fi

# ── 4. Remove all url.insteadOf rewrites this tool installed ─────────────────
if want insteadof; then
  step "Section 4: remove git url.insteadOf rewrites"
  # We don't know exactly which path was used (depends on --workdir). Find any
  # rewrite that maps to https://github.com/forcedotcom/afv-library and offer
  # to remove it.
  REWRITES=$(git config --global --get-regexp '^url\..*\.insteadOf$' 2>/dev/null \
    | awk '$2 == "https://github.com/forcedotcom/afv-library" { print $1 }')
  if [[ -z "$REWRITES" ]]; then
    info "No matching insteadOf rewrites found."
  else
    echo "$REWRITES" >&2
    if confirm "Remove these rewrite(s)?"; then
      while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        git config --global --unset-all "$key"
        info "Unset $key"
      done <<< "$REWRITES"
    fi
  fi
fi

# ── 5. Wipe the workdir ──────────────────────────────────────────────────────
if want workdir && ! $KEEP_WORKDIR; then
  step "Section 5: wipe workdir"
  if [[ -z "$WORKDIR" ]]; then
    if $YES; then
      info "Skipping workdir wipe — pass --workdir DIR to enable."
    else
      read -r -p "Workdir to wipe (blank to skip): " WORKDIR </dev/tty || true
    fi
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    if confirm "Delete $WORKDIR ?"; then
      /bin/rm -rf "$WORKDIR"
      log "Wiped $WORKDIR"
    fi
  elif [[ -n "$WORKDIR" ]]; then
    info "Workdir does not exist: $WORKDIR"
  fi
fi

echo
log "Uninstall complete."
echo "   To restore the originally-shipped AFV/sf-templates extension," >&2
echo "   reinstall via your normal channel (VS Code marketplace, npm, etc.)." >&2
