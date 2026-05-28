# afv-install-2

One script that wires up local sf CLI + VS Code to consume in-flight changes
across the AFV / templates / sf-cli stack via `npm link`, then drops the
latest skills from a PR into Einstein-GPT.

## Quick start (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/install.sh | bash -s -- --keep
```

This clones the repo into `~/.afv-install-2`, runs preflight checks, then
runs all 8 install steps. Pass any flags through `bash -s --` (e.g.
`--skip 6` to skip the slow VS Code VSIX rebuild).

## Or clone and run manually

```bash
git clone https://github.com/k-j-kim/afv-install-2.git
cd afv-install-2
bash preflight.sh                       # check prerequisites
bash sfdx-local-test-install.sh --keep  # actual install
```

## Preflight

`preflight.sh` checks for required tools (gh, git, node>=22, npm, sf, code,
python3, zip), confirms `gh` is logged in with access to each repo owner the
script will clone (forcedotcom, salesforcecli, salesforce-experience-platform-emu,
salesforce-internal), and verifies disk space. Run it standalone any time:

```bash
bash preflight.sh           # full output
bash preflight.sh --quiet   # only print failures
bash preflight.sh --json    # machine-readable
```

The internal Salesforce repos (`salesforce-experience-platform-emu`,
`salesforce-internal`) need a `gh` account with org access. The script will
auto-pick whichever logged-in account has access — no config edits needed.
If you're missing access, those steps surface as preflight warnings.

## Uninstall (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/uninstall-curl.sh | bash
# or non-interactive:
curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install-2/main/uninstall-curl.sh | bash -s -- -y
```

Or from a local clone:

```bash
bash uninstall.sh           # interactive — confirms each section
bash uninstall.sh -y        # non-interactive
```

## Steps

1. Install local AFV `.vsix` (path in `repos.conf` / `LOCAL_VSIX`)
2. `webapps` → `salesforcedx-templates` (npm link every webapps package
   `salesforcedx-templates` declares as a dep)
3. `salesforcedx-templates` → `plugin-templates` (npm link `@salesforce/templates`)
4. `sf plugins link` plugin-templates into local sf CLI
5. `salesforcedx-templates` → `salesforcedx-vscode` (npm link into every
   monorepo package that depends on `@salesforce/templates`)
6. `vsce package` every VS Code extension in `salesforcedx-vscode/packages/*`
   and `code --install-extension` each
7. Install skills from `sf-skills-internal` PR #157 into Einstein-GPT's
   `Skills-Salesforce/`

Step 8 (sample-apps override from PR #289) is **planned, not implemented** —
see `SAMPLE_APPS_PLAN.md`. Mechanism is unconfirmed.

## Usage

```bash
bash sfdx-local-test-install.sh             # all steps, scratch workdir
bash sfdx-local-test-install.sh --keep      # keep workdir for inspection
bash sfdx-local-test-install.sh --only 1,7  # only these step numbers
bash sfdx-local-test-install.sh --skip 6    # everything except this one
bash sfdx-local-test-install.sh --workdir ~/repo/_scratch/afv  # reuse a dir
```

All clones land under `--workdir` (auto-created tmp by default). The script
auto-switches `gh auth` between your public and internal accounts based on
the repo owner — set `GH_ACCOUNT_PUBLIC` / `GH_ACCOUNT_INTERNAL` /
`INTERNAL_OWNERS` in `repos.conf`.

## Requirements

`gh` (logged in to both public + internal), `git`, `node`, `npm`, `sf`, `code`.
`jq` is optional. `vsce` is auto-installed for step 6.

## Notes

- `npm link` chains are rebuilt every run (the workdir is fresh). If you pass
  `--workdir` to a directory that already has clones, the script reuses them
  and re-links — handy for iterating.
- `sf plugins link` persists across runs. To unlink:
  `sf plugins unlink @salesforce/plugin-templates`.
- VSIX installs are idempotent (`--force`). Reload the VS Code window after
  installs.
