# Sample-apps override plan for salesforcedx-vscode-einstein-gpt

Goal: when running the locally-installed Einstein-GPT VSIX, have the extension
serve sample apps from sf-skills-internal PR #289 instead of the version it
ships with.

## What PR #289 actually changes

`@W-22568671 chore: update react sample apps version to 9.9.4` modifies, in the
sf-skills-internal repo:

- `samples/ui-bundle-template-app-react-sample-b2e/**` (full tree: force-app,
  AGENT.md, .version, package.json bumps, etc.)
- `samples/ui-bundle-template-app-react-sample-b2x/**` (presumably; PR diff
  starts with `b2e` and continues — confirm)
- root `package.json` / `package-lock.json` bumps
- `.version` files inside each sample

So the artifact we need to override is the **`samples/ui-bundle-template-app-react-sample-*`** trees.

## Where the extension reads sample apps from

This is the unknown. There are three plausible mechanisms — confirm one before
implementing:

1. **Bundled inside the VSIX**: the extension copies a `samples/` directory at
   package time and reads from `<extension-install>/samples/...` at runtime.
2. **Downloaded at runtime** from a Salesforce-hosted endpoint (CDN / GitHub
   release) keyed by version.
3. **npm-installed** via a `@salesforce/ui-bundle-template-app-react-sample-*`
   dependency in one of the extension's packages.

### How to confirm

```bash
# After installing the AFV vsix (step 1 of the main script):
EXT="$HOME/.vscode/extensions"
ls "$EXT" | grep -i einstein
# Then inside the matched dir:
grep -RIn "ui-bundle-template-app-react-sample" .
grep -RIn "samples/" package.json
```

## Override strategy by mechanism

### If (1) — bundled in the VSIX

Two clean options:

- **Rebuild path**: clone the einstein-gpt VSIX source, replace its `samples/`
  with the PR #289 tree, run `vsce package`, reinstall. This is the only
  tamper-evident option but needs source access to the einstein-gpt VSIX repo
  (which is private — we already have the published `.vsix` but not source).
- **In-place replace**: locate the installed extension under
  `~/.vscode/extensions/salesforce.salesforcedx-einstein-gpt-*/`, swap its
  `samples/` for a symlink to the PR-#289 checkout, restart VS Code. Fast,
  reversible, but VS Code may rewrite the dir on update.

Recommend **in-place symlink** as a step 8 — easy, fully scriptable.

### If (2) — downloaded at runtime

Look for the URL/manifest in the extension code. Two options:

- Run a local file server (`npx http-server`) over the PR-#289 checkout and
  point the extension at it via a setting (look for an `eingpt.*` or
  `salesforcedx.*` setting in package.json contributions).
- If no setting exists, MITM via `/etc/hosts` + a local server with the right
  TLS cert — heavyweight; avoid unless setting-based override doesn't exist.

### If (3) — npm-installed dep

Add this to the main script's chain: clone PR #289, find the
`samples/ui-bundle-template-app-react-sample-*` packages, `npm link` each,
then `npm link <name>` in whichever AFV package consumes them. Same pattern
as steps 2/3/5 of the main script.

## Recommended next move

Run the main script through step 1, then run the confirmation grep above to
identify the mechanism. I'll add a step 8 to `sfdx-local-test-install.sh` once
we know which of the three it is.

## Step-8 sketch (in-place symlink, mechanism 1)

```bash
if want_step 8; then
  step "Step 8: override sample apps from PR #$SAMPLE_APPS_PR_NUMBER"
  ensure_gh_account_for "$(owner_of "$SAMPLE_APPS_PR_REPO")"
  HEAD_REF="$(gh pr view "$SAMPLE_APPS_PR_NUMBER" --repo "$SAMPLE_APPS_PR_REPO" --json headRefName -q .headRefName)"
  SRC="$(clone_into_workdir "${SAMPLE_APPS_PR_REPO}@${HEAD_REF}")/samples"

  # Glob the installed extension dir — version suffix changes per release
  EXT_DIR="$(ls -d "$HOME/.vscode/extensions/salesforce.salesforcedx-einstein-gpt-"* 2>/dev/null | sort -V | tail -1)"
  [[ -n "$EXT_DIR" ]] || die "Einstein-GPT extension not installed"

  if [[ -e "$EXT_DIR/samples" && ! -L "$EXT_DIR/samples" ]]; then
    mv "$EXT_DIR/samples" "$EXT_DIR/samples.orig.$(date +%s)"
  fi
  rm -f "$EXT_DIR/samples"
  ln -s "$SRC" "$EXT_DIR/samples"
  info "Symlinked $EXT_DIR/samples → $SRC"
  warn "Reload VS Code window for changes to take effect"
fi
```

This block intentionally lives in the plan, not the script, because the
mechanism is unconfirmed.
