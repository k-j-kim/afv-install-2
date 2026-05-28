#!/usr/bin/env bash
# uninstall-curl.sh — bootstrap entry point for `curl ... | bash`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/uninstall-curl.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/uninstall-curl.sh | bash -s -- -y
#
# Refreshes the local checkout in ~/.afv-install-2 (so any uninstall.sh
# improvements are picked up), then runs uninstall.sh from it.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

REPO_URL="${AFV_INSTALL_REPO:-https://github.com/k-j-kim/afv-install-2.git}"
REPO_BRANCH="${AFV_INSTALL_BRANCH:-main}"
CHECKOUT_DIR="${AFV_INSTALL_DIR:-$HOME/.afv-install-2}"

for c in git bash; do
  command -v "$c" >/dev/null || die "Missing required command: $c"
done

if [[ -d "$CHECKOUT_DIR/.git" ]]; then
  log "Refreshing $CHECKOUT_DIR"
  git -C "$CHECKOUT_DIR" fetch --quiet origin "$REPO_BRANCH" || true
  git -C "$CHECKOUT_DIR" checkout --quiet "$REPO_BRANCH" || true
  git -C "$CHECKOUT_DIR" reset --hard --quiet "origin/$REPO_BRANCH" || true
else
  log "Cloning $REPO_URL → $CHECKOUT_DIR"
  git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CHECKOUT_DIR"
fi

[[ -x "$CHECKOUT_DIR/uninstall.sh" ]] \
  || die "uninstall.sh missing or not executable at $CHECKOUT_DIR"

log "Running uninstall.sh $*"
exec bash "$CHECKOUT_DIR/uninstall.sh" "$@"
