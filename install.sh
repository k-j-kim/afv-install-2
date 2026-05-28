#!/usr/bin/env bash
# install.sh — bootstrap entry point for `curl ... | bash`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/install.sh | bash -s -- --skip 6
#
# What it does:
#   1. Clones (or refreshes) https://github.com/k-j-kim/afv-install-2 into
#      ~/.afv-install-2
#   2. Invokes ./sfdx-local-test-install.sh from that checkout, passing
#      through any args you provided to bash.
#
# Requires: gh logged in to your public + (if you have access) internal
# Salesforce GitHub accounts; the script auto-picks the right one per repo.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

REPO_URL="${AFV_INSTALL_REPO:-https://github.com/k-j-kim/afv-install-2.git}"
REPO_BRANCH="${AFV_INSTALL_BRANCH:-main}"
CHECKOUT_DIR="${AFV_INSTALL_DIR:-$HOME/.afv-install-2}"

for c in git bash; do
  command -v "$c" >/dev/null || die "Missing required command: $c"
done

if [[ -d "$CHECKOUT_DIR/.git" ]]; then
  log "Refreshing $CHECKOUT_DIR"
  git -C "$CHECKOUT_DIR" fetch --quiet origin "$REPO_BRANCH"
  git -C "$CHECKOUT_DIR" checkout --quiet "$REPO_BRANCH"
  git -C "$CHECKOUT_DIR" reset --hard --quiet "origin/$REPO_BRANCH"
else
  log "Cloning $REPO_URL → $CHECKOUT_DIR"
  git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CHECKOUT_DIR"
fi

[[ -x "$CHECKOUT_DIR/sfdx-local-test-install.sh" ]] \
  || die "sfdx-local-test-install.sh missing or not executable at $CHECKOUT_DIR"

# Preflight check — bail early if the host is missing prerequisites.
if [[ "${AFV_INSTALL_SKIP_PREFLIGHT:-}" != "1" ]]; then
  log "Running preflight checks (set AFV_INSTALL_SKIP_PREFLIGHT=1 to bypass)"
  if ! bash "$CHECKOUT_DIR/preflight.sh"; then
    die "Preflight failed — fix the items above and re-run."
  fi
fi

log "Running sfdx-local-test-install.sh $*"
exec bash "$CHECKOUT_DIR/sfdx-local-test-install.sh" "$@"
