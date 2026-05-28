# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this repo is

A single bash script (`sfdx-local-test-install.sh`) plus config (`repos.conf`)
that stands up a local **sf CLI + VS Code** environment consuming in-flight
changes across the AFV / Einstein-GPT stack:

```
webapps  →  salesforcedx-templates  →  plugin-templates  →  sf CLI
                                   ↘
                                     salesforcedx-vscode  →  VSIX bundles
```

Plus: AFV skills from a PR, and a `git url.insteadOf` rewrite that overrides
the sample-apps source the AFV extension clones at runtime.

There is **no production code, no tests, no CI**. This is a developer setup
script. Treat changes the way you'd treat changes to a Makefile.

## When the user asks you to "run the setup" / "install" / "test it"

1. Wipe prior state cleanly first:
   ```bash
   git config --global --unset-all 'url./Users/<you>/repo/_scratch/afv/afv-library.insteadOf' 2>&1 || true
   sf plugins unlink @salesforce/plugin-templates 2>&1 || true
   /bin/rm -rf <workdir>
   ```
   (`/bin/rm` not `rm` — the harness sandbox blocks `rm -rf` but allows the
   absolute path.)
2. Run with `--keep` and a persistent `--workdir` so the user can inspect:
   ```bash
   bash sfdx-local-test-install.sh --workdir ~/repo/_scratch/afv --keep
   ```
3. Long-running (10–20 min). Use `run_in_background: true` so you don't block.
4. After it finishes, verify with `sf` CLI — see "Verification" below.

## When the user asks you to "verify" / "check it works"

Always run the actual `sf` CLI command. File-presence checks lie because
intermediate caches (`yarn install`, `wireit`, `npm link`) often produce
files that *exist* but aren't what `sf` resolves at runtime.

```bash
# Confirms steps 2 + 3 + 4: customApplication metadata flows from
# webapps → salesforcedx-templates → plugin-templates → sf
TMP=$(mktemp -d) && cd "$TMP"
sf template generate project --template reactinternalapp --output-dir . --name myapp
ls myapp/force-app/main/default/applications/    # should have myapp.app-meta.xml
cat myapp/force-app/main/default/applications/myapp.app-meta.xml
/bin/rm -rf "$TMP"

# Confirms step 8: AFV's runtime clone of afv-library hits the local repo
git clone --depth 1 --single-branch --no-tags \
  https://github.com/forcedotcom/afv-library /tmp/afv-test
cat /tmp/afv-test/samples/ui-bundle-template-app-react-sample-b2e/.version
/bin/rm -rf /tmp/afv-test
```

## Auth gotchas

- The script needs **two `gh` accounts** logged in: one with access to public
  `forcedotcom/*` and `salesforcecli/*` repos, one with access to internal
  `salesforce-experience-platform-emu/*` and `salesforce-internal/*`.
- It auto-switches via `gh auth switch` per-repo. Account names live in
  `repos.conf`: `GH_ACCOUNT_PUBLIC` and `GH_ACCOUNT_INTERNAL`.
- If a clone fails with 404, first thing to check is `gh auth status` — the
  active account may not have access. The internal repos are NOT visible
  from the public account.

## Step ordering matters — don't reorder casually

The npm-link / yarn-link chain is fragile because both `salesforcedx-templates`
and `plugin-templates` use yarn with frozen lockfiles. The order is:

1. **Step 2 (webapps → templates)**: `yarn install --ignore-scripts` first
   (pulls registry versions), THEN swap `node_modules/<consumed>` for
   symlinks to local webapps source, THEN `yarn build` (the build's
   `scripts/copy-templates.js` reads from `node_modules` via `require.resolve`,
   which follows our symlinks into the local webapps `dist/`).
2. **Step 3 (templates → plugin-templates)**: `yarn install --ignore-scripts`,
   then `yarn run compile` (force-clean wireit cache first or `utils/flags.js`
   silently goes missing), THEN symlink `@salesforce/templates`. Build LAST,
   otherwise wireit re-runs install and clobbers the symlink.
3. **Step 5 (templates → vscode)**: clean `npm install` first, then symlink
   `@salesforce/templates` into each consumer's `node_modules` (NOT the root
   — that breaks `vscode:package`'s `npm list --production` integrity check).
4. **Step 6**: `npm run vscode:bundle` (esbuild inlines templates), then
   REMOVE the per-package symlinks (otherwise `vscode:package` rejects them
   as extraneous), then `npm run vscode:package`.

If you're tempted to "simplify" the script by changing this ordering, read
the inline comments and run a verify (above) before claiming success.

## Common failure modes

| Symptom | Likely cause |
|---|---|
| `sf template generate project --template reactinternalapp` produces output but no `applications/` dir | Step 2's symlink got clobbered by yarn install OR step 3's symlink got clobbered by wireit. Check `realpath` on `node_modules/@salesforce/templates`. |
| `vsce package` fails with "Run npm install from the repo root" | `INIT_CWD` env var not propagating into `vscode:prepublish`. Make sure the per-package vsce loop sets `INIT_CWD="$VSCODE_DIR"`. |
| `npm list --production` complains about extraneous `@salesforce/templates` | A symlink is still in place during `vscode:package`. Step 6 must remove all per-package + root symlinks before invoking the wireit `vscode:package` task. |
| `gh repo clone --branch <pr-branch>` fails with "Remote branch not found" | PR is from a fork. Use `gh repo clone <base>` then `gh pr checkout <number>` instead. Step 7 already does this. |
| AFV extension clones samples from the public afv-library, ignoring step 8 | The `git config insteadOf` is global; check `git config --global --get-regexp '^url\.'`. The path on the right side must match the URL the extension hardcodes (`https://github.com/forcedotcom/afv-library`) exactly, no trailing `.git`. |

## Non-obvious facts about the upstream repos

- **webapps** publishes packages whose names *match* what salesforcedx-templates
  declares as devDeps, but the **versions don't match** — webapps is at 9.x;
  salesforcedx-templates pins to 1.x. `npm link` is the only way to get the
  real (newer) source into the build.
- **salesforcedx-templates' build** has a copy step (`scripts/copy-templates.js`)
  that uses `require.resolve(packageName/package.json)` to find each
  `@salesforce/ui-bundle-template-*` and copies its `dist/` into
  `src/templates/project/<name>/`. This is what the runtime ships, NOT
  the registry packages.
- **`test/fixtures/project-templates/project`** is mocha test data, NOT
  shipped to consumers. Don't update it as part of the propagation chain.
- **AFV extension fetches sample apps via `git clone`**, not via npm or
  HTTPS-download. URL is hardcoded to `https://github.com/forcedotcom/afv-library`.
  See `dist/extension.js` `cloneWithSubdirectory` for the runtime call.

## Editing the script

- macOS ships bash 3.2 — no `declare -A` (associative arrays). Use
  parallel `NAMES=()` / `DIRS=()` arrays with a lookup function.
- All log helpers (`log`, `info`, `warn`) write to **stderr**, so functions
  like `clone_into_workdir` can `echo "$path"` to stdout for capture via
  `$(...)`. Don't `echo` log lines to stdout — it'll corrupt callers.
- `set -euo pipefail` is on. Watch for unset vars in conditional branches;
  initialize early.

## What NOT to add to this repo

- Don't commit a CI workflow. The end-to-end run takes 10-20 min and pulls
  multi-GB of node_modules; it doesn't belong in CI.
- Don't add tests for the bash script itself. Verification IS the `sf` CLI
  command at the bottom of a run.
- Don't add an installer that publishes the repo to a registry. The
  `bash <(curl ...)` pattern from the README is the deployment story.
