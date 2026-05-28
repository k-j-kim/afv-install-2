#!/usr/bin/env bash
# sfdx-local-test-install.sh
#
# Stand up a local sf CLI + VS Code environment that consumes in-progress changes
# across the webapps → salesforcedx-templates → plugin-templates / salesforcedx-vscode
# chain via npm link, then installs Einstein-GPT (AFV) plus skills from a PR.
#
# All clones happen under a single temp working directory so the host filesystem
# stays clean. Pass --keep to preserve the workdir for inspection.
#
# Usage:
#   bash sfdx-local-test-install.sh [--keep] [--workdir DIR] [--skip STEPS]
#   bash sfdx-local-test-install.sh --only 1,7
#
# Steps:
#   1  install local AFV vsix (from LOCAL_VSIX in repos.conf)
#   2  webapps          → salesforcedx-templates    (npm link)
#   3  salesforcedx-templates → plugin-templates    (npm link)
#   4  link plugin-templates into local sf CLI
#   5  salesforcedx-templates → salesforcedx-vscode (npm link, only packages that consume it)
#   6  build vsix from salesforcedx-vscode and install into VS Code
#   7  install AFV skills from sf-skills-internal PR #${SKILLS_PR_NUMBER} into Skills-Salesforce/
#   8  override the AFV sample-app source via git url.insteadOf with PR #${SAMPLE_APPS_PR_NUMBER}

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

ensure_gh_account_for() {
  local owner="$1" target=""
  if is_internal_owner "$owner"; then target="$GH_ACCOUNT_INTERNAL"
  else target="$GH_ACCOUNT_PUBLIC"; fi
  local active
  active="$(gh auth status 2>&1 | awk '/Active account: true/{f=1; next} f && /Logged in to/{print $NF; exit}')" || true
  # Fallback parse
  if [[ -z "$active" ]]; then
    active="$(gh auth status 2>&1 | grep -B1 'Active account: true' | grep 'account ' | awk '{print $NF}' | head -1)"
  fi
  if [[ "$active" != "$target" ]]; then
    log "Switching gh account → $target (for $owner)"
    gh auth switch --user "$target" >/dev/null
  fi
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
  echo "$dest"
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

# Find every package.json under a path that declares a dep on a given pkg name
# (in dependencies, devDependencies, or peerDependencies). Prints paths.
find_consumers_of() {
  local root="$1" pkg_name="$2"
  # Skip node_modules
  while IFS= read -r -d '' pj; do
    node -e "
      const p=require('$pj');
      const all={...(p.dependencies||{}),...(p.devDependencies||{}),...(p.peerDependencies||{})};
      if (all['$pkg_name']) console.log('$pj');
    " 2>/dev/null
  done < <(find "$root" -name package.json -not -path '*/node_modules/*' -print0)
}

# ── Step 1: install the local AFV vsix ────────────────────────────────────────
if want_step 1; then
  step "Step 1: install local AFV vsix"
  if [[ -f "$LOCAL_VSIX" ]]; then
    code --install-extension "$LOCAL_VSIX" --force
    info "Installed: $LOCAL_VSIX"
  else
    warn "LOCAL_VSIX not found: $LOCAL_VSIX — skipping"
  fi
fi

# ── Step 2: webapps → salesforcedx-templates (npm link) ───────────────────────
# webapps is an nx/lerna monorepo. salesforcedx-templates devDepends on
# @salesforce/ui-bundle-template-* packages that live inside webapps. We link
# every webapps package whose name appears in salesforcedx-templates'
# package.json deps/devDeps.
WEBAPPS_DIR=""; TEMPLATES_DIR=""
if want_step 2; then
  step "Step 2: webapps → salesforcedx-templates (npm link)"
  WEBAPPS_DIR="$(clone_into_workdir "$WEBAPPS_REPO")"
  TEMPLATES_DIR="$(clone_into_workdir "$TEMPLATES_REPO")"
  install_and_build "$WEBAPPS_DIR"

  # Build a parallel-array map: WEBAPPS_NAMES[i] → WEBAPPS_DIRS[i]
  WEBAPPS_NAMES=(); WEBAPPS_DIRS=()
  while IFS= read -r -d '' pj; do
    name="$(pkg_field "$pj" name)"
    [[ -z "$name" ]] && continue
    private="$(pkg_field "$pj" private || true)"
    [[ "$private" == "true" ]] && continue
    WEBAPPS_NAMES+=("$name")
    WEBAPPS_DIRS+=("$(dirname "$pj")")
  done < <(find "$WEBAPPS_DIR/packages" -mindepth 2 -maxdepth 6 -name package.json -not -path '*/node_modules/*' -print0)

  # Lookup helper
  webapps_dir_for() {
    local q="$1" i
    for i in "${!WEBAPPS_NAMES[@]}"; do
      [[ "${WEBAPPS_NAMES[$i]}" == "$q" ]] && { echo "${WEBAPPS_DIRS[$i]}"; return 0; }
    done
    return 1
  }

  # Determine which of these names salesforcedx-templates consumes
  CONSUMED_NAMES=()
  while IFS= read -r name; do
    if webapps_dir_for "$name" >/dev/null; then CONSUMED_NAMES+=("$name"); fi
  done < <(node -e "
    const p=require('$TEMPLATES_DIR/package.json');
    const all={...(p.dependencies||{}),...(p.devDependencies||{})};
    Object.keys(all).forEach(k=>console.log(k));
  ")

  if [[ ${#CONSUMED_NAMES[@]} -eq 0 ]]; then
    warn "No webapps packages are consumed by salesforcedx-templates — nothing to link"
  else
    log "Linking ${#CONSUMED_NAMES[@]} webapps package(s) into salesforcedx-templates:"
    for n in "${CONSUMED_NAMES[@]}"; do info "$n  ($(webapps_dir_for "$n"))"; done

    # salesforcedx-templates uses yarn with a frozen lockfile pinning these
    # packages to a stale registry version (1.x). yarn won't honor `npm link`
    # in node_modules, so we:
    #   1. yarn install --no-frozen-lockfile (don't fail on lockfile drift)
    #   2. swap each consumed dep's node_modules dir for a symlink to the
    #      local webapps source dir
    #   3. RE-RUN the build — its postinstall/prepare step copies these into
    #      src/templates/project/<name>/, baking the local code into the
    #      packaged @salesforce/templates that downstream consumers will use.
    log "yarn install --ignore-scripts in salesforcedx-templates"
    ( cd "$TEMPLATES_DIR" && yarn install --ignore-scripts )

    NM="$TEMPLATES_DIR/node_modules"
    for n in "${CONSUMED_NAMES[@]}"; do
      target_dir="$NM/$n"
      src_dir="$(webapps_dir_for "$n")"
      [[ -d "$src_dir" ]] || { warn "missing webapps src for $n"; continue; }
      /bin/rm -rf "$target_dir"
      mkdir -p "$(dirname "$target_dir")"
      ln -s "$src_dir" "$target_dir"
      info "Symlinked $n → $src_dir"
    done

    # Run the templates build so the copy step (Copied @salesforce/... →
    # src/templates/project/) consumes our linked sources.
    log "Building salesforcedx-templates so it picks up linked sources"
    ( cd "$TEMPLATES_DIR" && yarn build )
  fi
  # Make salesforcedx-templates itself linkable
  ( cd "$TEMPLATES_DIR" && npm link >/dev/null )
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

  PT_NM="$PLUGIN_TEMPLATES_DIR/node_modules/@salesforce"
  /bin/rm -rf "$PT_NM/templates"
  mkdir -p "$PT_NM"
  ln -s "$TEMPLATES_DIR" "$PT_NM/templates"
  info "Symlinked @salesforce/templates → $TEMPLATES_DIR"
fi

# ── Step 4: link plugin-templates into local sf CLI ───────────────────────────
if want_step 4; then
  step "Step 4: sf plugins link plugin-templates"
  [[ -z "$PLUGIN_TEMPLATES_DIR" ]] && PLUGIN_TEMPLATES_DIR="$WORKDIR/plugin-templates"
  [[ -d "$PLUGIN_TEMPLATES_DIR" ]] || die "plugin-templates not present — run step 3 first"
  sf plugins link "$PLUGIN_TEMPLATES_DIR"
fi

# ── Step 5: clone + build salesforcedx-vscode CLEAN (no link yet) ─────────────
# Linking @salesforce/templates here would pollute the dep tree and break
# step 6's `npm list --production` check inside vscode:package. We instead
# patch the *installed* extension after step 6 (see VSCODE_TEMPLATES_PATCH).
VSCODE_DIR=""
VSCODE_TEMPLATES_CONSUMERS=()
VSCODE_TEMPLATES_LINKS=()
if want_step 5; then
  step "Step 5: clone + build salesforcedx-vscode, link templates pre-bundle"
  [[ -z "$TEMPLATES_DIR" ]] && TEMPLATES_DIR="$(clone_into_workdir "$TEMPLATES_REPO")"
  VSCODE_DIR="$(clone_into_workdir "$VSCODE_REPO")"
  install_and_build "$VSCODE_DIR"

  # Find consumer dirs and symlink @salesforce/templates into each one's
  # private node_modules (not the root — that would break vscode:package's
  # `npm list --production` integrity check).
  CONSUMER_DIRS=()
  while IFS= read -r pj; do CONSUMER_DIRS+=("$(dirname "$pj")"); done < <(find_consumers_of "$VSCODE_DIR" "@salesforce/templates")
  for c in "${CONSUMER_DIRS[@]}"; do
    info "Linking @salesforce/templates into ${c#$VSCODE_DIR/}/node_modules"
    mkdir -p "$c/node_modules/@salesforce"
    /bin/rm -rf "$c/node_modules/@salesforce/templates"
    ln -s "$TEMPLATES_DIR" "$c/node_modules/@salesforce/templates"
    VSCODE_TEMPLATES_LINKS+=("$c/node_modules/@salesforce/templates")
  done
  [[ ${#CONSUMER_DIRS[@]} -eq 0 ]] && warn "No vscode package consumes @salesforce/templates"
fi

# ── Step 6: build vsix from salesforcedx-vscode, install, then patch ─────────
if want_step 6; then
  step "Step 6: package and install salesforcedx-vscode VSIX(s)"
  [[ -z "$VSCODE_DIR" ]] && VSCODE_DIR="$WORKDIR/salesforcedx-vscode"
  [[ -d "$VSCODE_DIR" ]] || die "salesforcedx-vscode not cloned — run step 5 first"
  [[ -z "$TEMPLATES_DIR" ]] && TEMPLATES_DIR="$WORKDIR/salesforcedx-templates"

  OUT_DIR="$WORKDIR/_vsix"; mkdir -p "$OUT_DIR"

  # The repo provides root scripts that wireit-orchestrate bundle + package
  # per extension. Use them — running vsce per-package fails because the
  # bundler step is owned by `vscode:bundle`, not `build`/`compile`.
  log "Running root vscode:bundle (esbuild per extension — picks up linked templates)"
  ( cd "$VSCODE_DIR" && npm run vscode:bundle )

  # Remove the per-package @salesforce/templates symlinks before vscode:package,
  # otherwise vsce's `npm list --production` rejects them as extraneous. The
  # bundler has already inlined the code into dist/ at this point.
  if [[ ${#VSCODE_TEMPLATES_LINKS[@]} -gt 0 ]]; then
    log "Removing pre-bundle symlinks (code is already inlined into dist/)"
    for l in "${VSCODE_TEMPLATES_LINKS[@]}"; do
      [[ -L "$l" ]] && /bin/rm -f "$l" && info "unlinked ${l#$VSCODE_DIR/}"
    done
  fi

  log "Running root vscode:package (vsce per extension)"
  ( cd "$VSCODE_DIR" && npm run vscode:package )

  # Collect produced VSIX files.
  packaged=0
  while IFS= read -r -d '' v; do
    cp "$v" "$OUT_DIR/"
    packaged=$((packaged+1))
  done < <(find "$VSCODE_DIR/packages" -maxdepth 2 -name '*.vsix' -print0)

  for v in "$OUT_DIR"/*.vsix; do
    [[ -f "$v" ]] || continue
    log "Installing $(basename "$v")"
    code --install-extension "$v" --force || warn "install failed: $v"
  done
  log "Packaged $packaged extension(s) into $OUT_DIR"
fi

# ── Step 7: install skills from sf-skills-internal PR #157 ────────────────────
if want_step 7; then
  step "Step 7: install skills from $SKILLS_PR_REPO PR #$SKILLS_PR_NUMBER"
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

# ── Step 8: override AFV sample-app source with PR #289 ──────────────────────
# The Einstein-GPT extension clones afv-library at runtime to fetch sample
# apps. We seed a local bare repo with afv-library + PR #289's updated
# samples spliced in, then add a global git url.insteadOf rewrite so the
# extension's `git clone https://github.com/forcedotcom/afv-library` resolves
# to that local repo. Idempotent and reversible.
if want_step 8; then
  step "Step 8: override sample apps from $SAMPLE_APPS_PR_REPO PR #$SAMPLE_APPS_PR_NUMBER"
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
