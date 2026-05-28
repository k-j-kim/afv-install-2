#!/usr/bin/env bash
# rebuild-vscode-vsix.sh — refresh the salesforcedx-vscode-{core,services}.vsix
# files in this repo's vsix/ directory.
#
# Run this when:
#  - salesforcedx-templates has been updated and you want the linked changes
#    baked into the shipped VSIX
#  - salesforcedx-vscode has tagged a new release worth picking up
#
# What it does:
#  1. Runs steps 2-3 of sfdx-local-test-install.sh — bumps the
#     ui-bundle-template-* deps to latest npm and rebuilds salesforcedx-templates
#  2. Clones salesforcedx-vscode, npm-installs it, runs compile
#  3. Symlinks the rebuilt @salesforce/templates into vscode-core/-services
#  4. Runs vscode:bundle for those two packages (esbuild inlines templates)
#  5. Runs vscode:package:legacy for those two packages (vsce produces .vsix)
#  6. Copies the produced .vsix files into <repo>/vsix/, replacing the
#     existing ones
#  7. Commits and pushes (unless --no-commit)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

NO_COMMIT=false
WORKDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-commit) NO_COMMIT=true; shift ;;
    --workdir)   WORKDIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
[[ -d "$REPO_ROOT/vsix" ]] || die "Expected $REPO_ROOT/vsix/ to exist"

# Reuse the main install script for steps 2 + 3 (yarn install + symlink chain).
# This guarantees we build with exactly the same setup the runtime uses.
TMPDIR_RUN="${WORKDIR:-$(mktemp -d -t afv-rebuild-XXXXXX)}"
log "Workdir: $TMPDIR_RUN"

bash "$REPO_ROOT/sfdx-local-test-install.sh" --workdir "$TMPDIR_RUN" --keep --only 2,3

TEMPLATES_DIR="$TMPDIR_RUN/salesforcedx-templates"
[[ -d "$TEMPLATES_DIR/lib/templates" ]] || die "Templates build didn't produce lib/templates"

VSCODE_BRANCH="${VSCODE_BRANCH:-develop}"
VSCODE_DIR="$TMPDIR_RUN/salesforcedx-vscode"
if [[ ! -d "$VSCODE_DIR/.git" ]]; then
  log "Cloning forcedotcom/salesforcedx-vscode@$VSCODE_BRANCH"
  gh repo clone forcedotcom/salesforcedx-vscode "$VSCODE_DIR" -- --depth 1 --branch "$VSCODE_BRANCH" >/dev/null
fi

# Drop public-registry .npmrc to bypass internal nexus configs.
cat > "$VSCODE_DIR/.npmrc" <<'EOF'
registry=https://registry.npmjs.org/
@salesforce:registry=https://registry.npmjs.org/
@oclif:registry=https://registry.npmjs.org/
@lwc:registry=https://registry.npmjs.org/
always-auth=false
EOF

log "npm install salesforcedx-vscode (~3500 pkgs, may take a few minutes)"
( cd "$VSCODE_DIR" && npm install )

log "npm run compile"
( cd "$VSCODE_DIR" && npm run compile )

# Find the consumer packages and symlink @salesforce/templates into each.
CONSUMERS=()
for pkg_dir in "$VSCODE_DIR"/packages/*/; do
  if [[ -f "$pkg_dir/package.json" ]] && \
     node -e "const p=require('$pkg_dir/package.json'); const all={...(p.dependencies||{}),...(p.devDependencies||{}),...(p.peerDependencies||{})}; process.exit(all['@salesforce/templates'] ? 0:1)"; then
    CONSUMERS+=("$pkg_dir")
    info_pkg="$(basename "$pkg_dir")"
    log "Linking @salesforce/templates → $info_pkg/node_modules"
    mkdir -p "$pkg_dir/node_modules/@salesforce"
    /bin/rm -rf "$pkg_dir/node_modules/@salesforce/templates"
    ln -s "$TEMPLATES_DIR" "$pkg_dir/node_modules/@salesforce/templates"
  fi
done
[[ ${#CONSUMERS[@]} -gt 0 ]] || die "No salesforcedx-vscode package consumes @salesforce/templates"

for pkg_dir in "${CONSUMERS[@]}"; do
  name="$(basename "$pkg_dir")"
  log "Bundling $name (esbuild inlines linked templates)"
  ( cd "$pkg_dir" && npm run vscode:bundle )
done

# Apply the same vsce workaround the main install script uses: hide nested
# package.json files so vsce's `npm install` doesn't recurse into them.
log "Patching vsce-bundled-extension.ts to hide nested package.json files"
BUNDLED_TS="$VSCODE_DIR/scripts/vsce-bundled-extension.ts"
if [[ -f "$BUNDLED_TS" && ! -f "$BUNDLED_TS.afv-orig" ]]; then
  cp "$BUNDLED_TS" "$BUNDLED_TS.afv-orig"
fi
if ! grep -q 'AFV_RENAME_NESTED' "$BUNDLED_TS"; then
  python3 - "$BUNDLED_TS" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
hide_block = """
import { renameSync as _afvRenameSync } from 'fs';
function _afvWalkRename(dir: string, suffix: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = `${dir}/${e.name}`;
    if (e.isDirectory()) out.push(..._afvWalkRename(full, suffix));
    else if ((e.name === 'package.json' || e.name === 'package-lock.json')
             && (full.includes('/dist/templates/') || full.includes('/extension/dist/templates/'))) {
      _afvRenameSync(full, full + suffix);
      out.push(full);
    }
  }
  return out;
}
const _afvHidden: string[] = [];
try {
  if (existsSync(`${cwd}/dist/templates`)) _afvHidden.push(..._afvWalkRename(`${cwd}/dist/templates`, '.afv-hidden'));
} catch (e) { logger('AFV hide failed: ' + (e as Error).message); }
logger(`AFV: hidden ${_afvHidden.length} nested package.json files`); // AFV_RENAME_NESTED
"""
restore_block = """
for (const f of _afvHidden) { try { _afvRenameSync(f + '.afv-hidden', f); } catch {} }
const _afvVsix = readdirSync(cwd).find((f) => f.endsWith('.vsix'));
if (_afvVsix && _afvHidden.length > 0) {
  const _path = require('path');
  const _afvVsixAbs = `${cwd}/${_afvVsix}`;
  for (const f of _afvHidden) {
    const idx = f.indexOf('/extension/'); if (idx === -1) continue;
    const inZip = f.slice(idx + 1);
    const stage = require('os').tmpdir() + '/afv-stage-' + Date.now() + Math.random();
    require('fs').mkdirSync(`${stage}/${_path.dirname(inZip)}`, { recursive: true });
    require('fs').copyFileSync(f, `${stage}/${inZip}`);
    try { execSync(`zip -qr "${_afvVsixAbs}" .`, { cwd: stage, stdio: 'pipe' }); } catch {}
    try { require('fs').rmSync(stage, { recursive: true, force: true }); } catch {}
  }
}
"""
src = re.sub(r"(\nlogger\('executing npm install'\);)", hide_block + r"\1", src, count=1)
src = re.sub(r"(logger\('copy vsix back to extension directory'\);)", restore_block + r"\1", src, count=1)
p.write_text(src)
PY
fi

for pkg_dir in "${CONSUMERS[@]}"; do
  name="$(basename "$pkg_dir")"
  log "Packaging $name (vsce)"
  ( cd "$pkg_dir" && npm run vscode:package:legacy ) || warn "vsce failed for $name"
done

# Copy produced .vsix into vsix/.
log "Copying produced .vsix files into $REPO_ROOT/vsix/"
copied=0
for pkg_dir in "${CONSUMERS[@]}"; do
  for v in "$pkg_dir"/*.vsix; do
    [[ -f "$v" ]] || continue
    name="$(basename "$v")"
    cp "$v" "$REPO_ROOT/vsix/$name"
    log "  → vsix/$name"
    copied=$((copied+1))
  done
done
[[ $copied -gt 0 ]] || die "No .vsix files were produced"

if ! $NO_COMMIT; then
  log "Committing + pushing"
  ( cd "$REPO_ROOT" && git add vsix/ && \
      git -c user.email=k.j.kim@salesforce.com -c user.name="KJ Kim" commit -m "chore: refresh bundled VS Code VSIX files

Rebuilt salesforcedx-vscode-core + -services VSIX with current
salesforcedx-templates main + webapps main." && \
      git push )
fi

log "Done. Workdir: $TMPDIR_RUN ($([ -n "$WORKDIR" ] && echo kept || echo will be deleted))"
[[ -z "$WORKDIR" ]] && /bin/rm -rf "$TMPDIR_RUN"
