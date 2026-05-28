#!/usr/bin/env bash
# sfdx-local-test-install.sh
#
# Stand up a local sf CLI + VS Code environment with up-to-date AFV
# (Einstein-GPT) extensions, an SF CLI templates plugin patched to pull
# the latest ui-bundle template packages from npm, and the latest skills
# from sf-skills-internal.
#
# All clones happen under a single temp working directory so the host filesystem
# stays clean. Pass --keep to preserve the workdir for inspection.
#
# Usage:
#   bash sfdx-local-test-install.sh [--keep] [--workdir DIR] [--skip STEPS]
#   bash sfdx-local-test-install.sh --only 1,7
#
# Steps:
#   1  install bundled VSIX files (AFV + salesforcedx-vscode-core + -services)
#   2  bump @salesforce/ui-bundle-template-* devDeps to latest + rebuild
#       salesforcedx-templates so its lib/templates/ has fresh content
#   3  symlink local salesforcedx-templates into plugin-templates + compile
#   4  link plugin-templates into local sf CLI
#   5  install AFV skills from sf-skills-internal PR #${SKILLS_PR_NUMBER}
#   6  override the AFV sample-app source via git url.insteadOf with PR #${SAMPLE_APPS_PR_NUMBER}
#
# Why steps 2-4 exist:
#   The published @salesforce/plugin-templates pins @salesforce/templates,
#   which in turn pins very stale (1.x) versions of the ui-bundle-template-*
#   packages. The new content (customApplication metadata, etc.) only ships
#   in 9.x on npm. We rebuild the chain locally with the bump applied so
#   `sf template generate project --template reactinternalapp` emits the
#   new files.
#
# The VS Code extensions are NOT rebuilt at install time — the repo ships
# pre-built VSIX files (vsix/salesforcedx-vscode-core-*.vsix, vsix/
# salesforcedx-vscode-services-*.vsix) that already have the linked
# templates inlined via esbuild. To refresh them, see
# scripts/rebuild-vscode-vsix.sh.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*" >&2; }
info() { echo -e "${BLUE}   ·${NC} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${GREEN}━━${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -f "$SCRIPT_DIR/repos.conf" ]] || die "repos.conf not found next to script"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/repos.conf"

# ── Args ──────────────────────────────────────────────────────────────────────
KEEP_WORKDIR=false
WORKDIR=""
ONLY=""
SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)    KEEP_WORKDIR=true; shift ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    --skip)    SKIP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

want_step() {
  local n="$1"
  if [[ -n "$ONLY" ]]; then [[ ",$ONLY," == *",$n,"* ]]; return; fi
  if [[ -n "$SKIP" ]]; then [[ ",$SKIP," != *",$n,"* ]]; return; fi
  return 0
}

# ── Deps ──────────────────────────────────────────────────────────────────────
for c in gh git node npm sf code; do command -v "$c" >/dev/null || die "Missing: $c"; done
command -v jq >/dev/null || warn "jq not found — will fall back to node for JSON edits"

# ── Workdir ───────────────────────────────────────────────────────────────────
if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d -t sfdx-local-test-XXXXXX)"
fi
mkdir -p "$WORKDIR"
log "Workdir: $WORKDIR"

cleanup() {
  if $KEEP_WORKDIR; then
    info "Keeping workdir at $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

# ── gh account juggling ───────────────────────────────────────────────────────
is_internal_owner() {
  local owner="$1"
  for io in "${INTERNAL_OWNERS[@]}"; do [[ "$owner" == "$io" ]] && return 0; done
  return 1
}

# All gh accounts logged in (regardless of which is active).
gh_logged_in_accounts() {
  gh auth status 2>&1 | awk '/Logged in to github.com account/ { for(i=1;i<=NF;i++) if($i=="account") print $(i+1) }'
}

gh_active_account() {
  gh auth status 2>&1 | awk '
    /Logged in to github.com account/ { last=$NF; for(i=1;i<=NF;i++) if($i=="account") last=$(i+1) }
    /Active account: true/ { print last; exit }
  '
}

# Pick the right gh account for a repo owner. Strategy:
#  1. If active account already has access (gh api repos/<owner>/... 200) → keep it.
#  2. Otherwise iterate over all logged-in accounts, switch to each, retest.
#  3. Cache the choice per owner so we don't probe repeatedly.
declare _GH_OWNER_CACHE_KEYS=""
_gh_owner_cache_get() {
  local owner="$1"
  echo "$_GH_OWNER_CACHE_KEYS" | awk -F= -v k="$owner" '$1==k{print $2; found=1} END{exit !found}'
}
_gh_owner_cache_set() {
  _GH_OWNER_CACHE_KEYS="$_GH_OWNER_CACHE_KEYS
$1=$2"
}

_gh_account_can_access() {
  local owner="$1"
  # Probe with a cheap, cacheable endpoint that works for both public + private orgs.
  gh api "users/$owner" --silent >/dev/null 2>&1 \
    && gh api "orgs/$owner/repos?per_page=1" --silent >/dev/null 2>&1 \
    || gh api "users/$owner/repos?per_page=1" --silent >/dev/null 2>&1
}

ensure_gh_account_for() {
  local owner="$1"
  local cached
  if cached="$(_gh_owner_cache_get "$owner")" 2>/dev/null && [[ -n "$cached" ]]; then
    local active="$(gh_active_account)"
    [[ "$active" != "$cached" ]] && gh auth switch --user "$cached" >/dev/null
    return 0
  fi

  local active="$(gh_active_account)"
  # Try the active account first
  if _gh_account_can_access "$owner"; then
    info "gh: using active account ($active) for $owner"
    _gh_owner_cache_set "$owner" "$active"
    return 0
  fi

  # Probe all logged-in accounts
  local acc
  while IFS= read -r acc; do
    [[ -z "$acc" || "$acc" == "$active" ]] && continue
    log "Trying gh account '$acc' for $owner"
    gh auth switch --user "$acc" >/dev/null
    if _gh_account_can_access "$owner"; then
      info "gh: using $acc for $owner"
      _gh_owner_cache_set "$owner" "$acc"
      return 0
    fi
  done < <(gh_logged_in_accounts)

  warn "No logged-in gh account has access to $owner — clones may 404."
  warn "Run: gh auth login   (and add the account that has access to $owner)"
  return 1
}

parse_repo()   { echo "${1%%@*}"; }
parse_branch() { local b="${1#*@}"; [[ "$b" == "$1" ]] && echo "main" || echo "$b"; }
owner_of()     { echo "${1%%/*}"; }

# Clone helper — clones into $WORKDIR/<basename>, returns path on stdout.
clone_into_workdir() {
  local repo_at="$1"
  local repo branch dest
  repo="$(parse_repo "$repo_at")"
  branch="$(parse_branch "$repo_at")"
  dest="$WORKDIR/${repo##*/}"
  ensure_gh_account_for "$(owner_of "$repo")"
  if [[ -d "$dest/.git" ]]; then
    info "Reusing $dest"
  else
    log "Cloning $repo@$branch"
    gh repo clone "$repo" "$dest" -- --depth 1 --branch "$branch" >/dev/null
  fi
  # Drop a public-registry .npmrc so users with internal nexus configs in their
  # global ~/.npmrc don't get rerouted (or fail auth) when this script runs
  # `npm install` / `yarn install` inside the cloned repo.
  write_public_npmrc "$dest"
  echo "$dest"
}

# Force every cloned repo to resolve npm packages from the public registry,
# bypassing whatever the user has in ~/.npmrc (e.g. nexus-proxy URLs that
# may need internal auth or rewrite scoped packages).
write_public_npmrc() {
  local dir="$1"
  cat > "$dir/.npmrc" <<'EOF'
# Auto-written by sfdx-local-test-install.sh. Forces public npm registry,
# overriding the user's global ~/.npmrc (which may point at an internal
# nexus proxy that requires auth or rewrites scoped packages).
registry=https://registry.npmjs.org/
@salesforce:registry=https://registry.npmjs.org/
@oclif:registry=https://registry.npmjs.org/
@lwc:registry=https://registry.npmjs.org/
always-auth=false
EOF
}

# Install + build helper — chooses npm or yarn based on lockfile.
install_and_build() {
  local dir="$1" build_script="${2:-build}"
  pushd "$dir" >/dev/null
  if [[ -f yarn.lock ]]; then
    log "yarn install in ${dir##*/}"
    yarn install --frozen-lockfile
    if grep -q "\"$build_script\"" package.json; then
      log "yarn $build_script in ${dir##*/}"
      yarn "$build_script"
    fi
  else
    log "npm install in ${dir##*/}"
    npm install
    if node -e "process.exit(!(require('./package.json').scripts||{}).$build_script ? 1 : 0)" 2>/dev/null; then
      log "npm run $build_script in ${dir##*/}"
      npm run "$build_script"
    fi
  fi
  popd >/dev/null
}

# Read a package.json field — uses jq if available, else node.
pkg_field() {
  local file="$1" field="$2"
  if command -v jq >/dev/null; then
    jq -r ".$field // empty" "$file"
  else
    node -e "const p=require('$file'); const v=p.$field; if(v!==undefined) console.log(typeof v==='string'?v:JSON.stringify(v))"
  fi
}

# ── Step 1: install bundled VSIX files ────────────────────────────────────────
if want_step 1; then
  step "Step 1: install bundled VSIX files"
  # Install every .vsix in the repo's vsix/ directory. Ships:
  #   - salesforcedx-einstein-gpt-*.vsix     (AFV / Einstein-GPT)
  #   - salesforcedx-vscode-core-*.vsix      (with linked templates inlined)
  #   - salesforcedx-vscode-services-*.vsix  (with linked templates inlined)
  vsix_dir="$SCRIPT_DIR/vsix"
  if [[ ! -d "$vsix_dir" ]]; then
    warn "vsix/ directory not found at $vsix_dir — skipping VSIX installs"
  else
    installed=0
    for v in "$vsix_dir"/*.vsix; do
      [[ -f "$v" ]] || continue
      log "Installing $(basename "$v")"
      code --install-extension "$v" --force >/dev/null && installed=$((installed+1)) \
        || warn "Failed to install $(basename "$v")"
    done
    log "Installed $installed VSIX file(s)"
  fi
fi

# ── Step 2: bump @salesforce/ui-bundle-template-* to latest + build ──────────
# salesforcedx-templates devDepends on @salesforce/ui-bundle-template-*
# packages but pins them to ^1.135.0 — many major versions behind. The
# customApplication metadata and the rest of the new template content
# all ship in 9.x on the public npm registry. We just bump the deps to
# `latest` and rebuild — no webapps clone, no symlink chain.
TEMPLATES_DIR=""
if want_step 2; then
  step "Step 2: bump ui-bundle-template-* deps to latest + build"
  TEMPLATES_DIR="$(clone_into_workdir "$TEMPLATES_REPO")"

  # Find every @salesforce/ui-bundle-template-* devDep and rewrite its
  # version to "latest" (resolved by yarn at install time).
  log "Rewriting @salesforce/ui-bundle-template-* devDeps → latest"
  node -e "
    const fs = require('fs');
    const path = '$TEMPLATES_DIR/package.json';
    const p = JSON.parse(fs.readFileSync(path, 'utf8'));
    const dd = p.devDependencies || {};
    let bumped = 0;
    for (const k of Object.keys(dd)) {
      if (k.startsWith('@salesforce/ui-bundle-template-')) {
        dd[k] = 'latest';
        bumped++;
      }
    }
    p.devDependencies = dd;
    fs.writeFileSync(path, JSON.stringify(p, null, 2) + '\n');
    console.error('   · bumped ' + bumped + ' template devDeps to latest');
  "

  log "yarn install (ignore-scripts) in salesforcedx-templates"
  # The lockfile pins the old 1.x — drop --frozen-lockfile so yarn re-resolves.
  ( cd "$TEMPLATES_DIR" && yarn install --ignore-scripts )

  log "yarn build (compiles + scripts/copy-templates pulls in fresh template files)"
  ( cd "$TEMPLATES_DIR" && yarn build )

  # The bumped template packages may contain a node_modules tree under
  # _p_/_m_/_w_/_a_/ (artifact of how they were published). It's not used
  # at runtime and trips up downstream consumers — strip it.
  stray_count=0
  while IFS= read -r -d '' nm; do
    /bin/rm -rf "$nm"
    stray_count=$((stray_count+1))
  done < <(find "$TEMPLATES_DIR/lib/templates" "$TEMPLATES_DIR/src/templates" \
            -type d -name node_modules -prune -print0 2>/dev/null)
  [[ $stray_count -gt 0 ]] && info "Removed $stray_count stray node_modules tree(s)"
fi

# ── Step 3: salesforcedx-templates → plugin-templates (npm link) ──────────────
PLUGIN_TEMPLATES_DIR=""
if want_step 3; then
  step "Step 3: salesforcedx-templates → plugin-templates (symlink + rebuild)"
  [[ -z "$TEMPLATES_DIR" ]] && TEMPLATES_DIR="$(clone_into_workdir "$TEMPLATES_REPO")"
  PLUGIN_TEMPLATES_DIR="$(clone_into_workdir "$PLUGIN_TEMPLATES_REPO")"

  # plugin-templates uses yarn with a frozen lockfile and a build script
  # (wireit) that may re-run installs — so we install + build first, THEN
  # symlink @salesforce/templates → local clone last. Otherwise the build
  # would clobber the symlink with a fresh registry install.
  log "yarn install --ignore-scripts in plugin-templates"
  ( cd "$PLUGIN_TEMPLATES_DIR" && yarn install --ignore-scripts )

  # Force a clean compile — wireit's incremental cache otherwise skips files
  # like utils/flags.ts on a re-run and the resulting lib/ is broken.
  /bin/rm -rf "$PLUGIN_TEMPLATES_DIR/lib" "$PLUGIN_TEMPLATES_DIR/.wireit" "$PLUGIN_TEMPLATES_DIR"/*.tsbuildinfo

  log "Compiling plugin-templates"
  ( cd "$PLUGIN_TEMPLATES_DIR" && yarn run compile )

  # NOTE: the @salesforce/templates symlink is intentionally created in
  # step 4 — `sf plugins link` runs its own install and would clobber a
  # symlink left here.
fi

# ── Step 4: link plugin-templates into local sf CLI ───────────────────────────
if want_step 4; then
  step "Step 4: sf plugins link plugin-templates"
  [[ -z "$PLUGIN_TEMPLATES_DIR" ]] && PLUGIN_TEMPLATES_DIR="$WORKDIR/plugin-templates"
  [[ -d "$PLUGIN_TEMPLATES_DIR" ]] || die "plugin-templates not present — run step 3 first"
  [[ -z "$TEMPLATES_DIR" ]] && TEMPLATES_DIR="$WORKDIR/salesforcedx-templates"
  [[ -d "$TEMPLATES_DIR" ]] || die "salesforcedx-templates not present — run step 2 first"

  sf plugins link "$PLUGIN_TEMPLATES_DIR"

  # `sf plugins link` re-runs npm/yarn install inside the linked plugin,
  # which replaces any pre-existing @salesforce/templates symlink with a
  # real install of the registry version. Symlink AFTER the link so our
  # local salesforcedx-templates is what actually loads.
  PT_NM="$PLUGIN_TEMPLATES_DIR/node_modules/@salesforce"
  /bin/rm -rf "$PT_NM/templates"
  mkdir -p "$PT_NM"
  ln -s "$TEMPLATES_DIR" "$PT_NM/templates"
  info "Symlinked @salesforce/templates → $TEMPLATES_DIR (post-link)"
fi


# ── Step 5: install skills from sf-skills-internal PR #157 ────────────────────
if want_step 5; then
  step "Step 5: install skills from $SKILLS_PR_REPO PR #$SKILLS_PR_NUMBER"
  ensure_gh_account_for "$(owner_of "$SKILLS_PR_REPO")"
  SKILLS_DIR_SRC="$WORKDIR/sf-skills-internal"
  if [[ ! -d "$SKILLS_DIR_SRC/.git" ]]; then
    log "Cloning $SKILLS_PR_REPO base + checking out PR #$SKILLS_PR_NUMBER (cross-repo safe)"
    gh repo clone "$SKILLS_PR_REPO" "$SKILLS_DIR_SRC" -- --depth 50 >/dev/null
    ( cd "$SKILLS_DIR_SRC" && gh pr checkout "$SKILLS_PR_NUMBER" )
  fi

  case "$(uname -s)" in
    Darwin) EINSTEIN_DIR="$HOME/Library/Application Support/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt" ;;
    Linux)  EINSTEIN_DIR="$HOME/.config/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt" ;;
    *) die "Unsupported OS" ;;
  esac
  TARGET="$EINSTEIN_DIR/Skills-Salesforce"
  mkdir -p "$TARGET"

  SRC="$SKILLS_DIR_SRC/$SKILLS_SUBDIR"
  [[ -d "$SRC" ]] || die "Expected $SRC in PR checkout"

  # Only touch directories that are present in this PR — don't blow away the world.
  copied=0
  while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    rm -rf "$TARGET/$name"
    cp -r "$d" "$TARGET/$name"
    info "Installed skill: $name"
    copied=$((copied+1))
  done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0)
  log "Installed $copied skill(s) into $TARGET"
fi

# ── Step 6: override AFV sample-app source with PR #289 ──────────────────────
# The Einstein-GPT extension clones afv-library at runtime to fetch sample
# apps. We seed a local bare repo with afv-library + PR #289's updated
# samples spliced in, then add a global git url.insteadOf rewrite so the
# extension's `git clone https://github.com/forcedotcom/afv-library` resolves
# to that local repo. Idempotent and reversible.
if want_step 6; then
  step "Step 6: override sample apps from $SAMPLE_APPS_PR_REPO PR #$SAMPLE_APPS_PR_NUMBER"
  ensure_gh_account_for "$(owner_of "$SAMPLE_APPS_PR_REPO")"

  # 1. Clone the upstream afv-library that the extension references.
  AFV_DIR="$WORKDIR/afv-library"
  if [[ ! -d "$AFV_DIR/.git" ]]; then
    log "Cloning forcedotcom/afv-library (sample source)"
    ensure_gh_account_for "forcedotcom"
    gh repo clone "forcedotcom/afv-library" "$AFV_DIR" -- --depth 1 >/dev/null
  fi

  # 2. Clone the PR fork and check out the PR head.
  ensure_gh_account_for "$(owner_of "$SAMPLE_APPS_PR_REPO")"
  PR_DIR="$WORKDIR/sample-apps-pr"
  if [[ ! -d "$PR_DIR/.git" ]]; then
    log "Cloning $SAMPLE_APPS_PR_REPO + checking out PR #$SAMPLE_APPS_PR_NUMBER"
    gh repo clone "$SAMPLE_APPS_PR_REPO" "$PR_DIR" -- --depth 50 >/dev/null
    ( cd "$PR_DIR" && gh pr checkout "$SAMPLE_APPS_PR_NUMBER" )
  fi

  # 3. Splice each sample dir from the PR into the afv-library checkout.
  spliced=0
  for d in "${SAMPLE_APPS_DIRS[@]}"; do
    src="$PR_DIR/samples/$d"
    dst="$AFV_DIR/samples/$d"
    if [[ ! -d "$src" ]]; then warn "PR is missing samples/$d — skipping"; continue; fi
    /bin/rm -rf "$dst"
    cp -R "$src" "$dst"
    info "Spliced: samples/$d"
    spliced=$((spliced+1))
  done

  if [[ $spliced -gt 0 ]]; then
    # 4. Commit splice so git clone --depth 1 sees it on default branch.
    ensure_gh_account_for "forcedotcom"  # restore origin owner; commit is local-only
    ( cd "$AFV_DIR" \
        && git -c user.email=local@noop -c user.name=local add samples \
        && git -c user.email=local@noop -c user.name=local commit -m "local: splice PR #$SAMPLE_APPS_PR_NUMBER samples" --quiet 2>/dev/null || true )
  fi

  # 5. Install global url.insteadOf so the extension's git clone resolves locally.
  log "Adding git config: url.\"$AFV_DIR\".insteadOf $AFV_LIBRARY_URL"
  git config --global --replace-all "url.$AFV_DIR.insteadOf" "$AFV_LIBRARY_URL"
  info "To revert: git config --global --unset url.$AFV_DIR.insteadOf"

  if ! $KEEP_WORKDIR; then
    warn "You ran without --keep, so $AFV_DIR will be deleted on exit."
    warn "The git insteadOf rewrite would then point at a missing path. Re-run with --keep,"
    warn "or move $AFV_DIR somewhere persistent and re-add the insteadOf rewrite."
  fi
fi

echo ""
log "Done."
echo "   Workdir: $WORKDIR  $($KEEP_WORKDIR && echo '(kept)' || echo '(will be deleted)')"
