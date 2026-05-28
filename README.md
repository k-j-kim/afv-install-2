# afv-install-2

One script that wires up local sf CLI + VS Code to consume in-flight changes
across the AFV / templates / sf-cli stack via `npm link`, then drops the
latest skills from a PR into Einstein-GPT.

## Quick start

```bash
git clone https://github.com/k-j-kim/afv-install-2.git
cd afv-install-2
bash sfdx-local-test-install.sh --keep
```

You need `gh` logged in for both your public and internal Salesforce GitHub
accounts (the script auto-switches via `gh auth switch` per repo owner).
Edit `GH_ACCOUNT_PUBLIC` / `GH_ACCOUNT_INTERNAL` in `repos.conf` if your
account names differ from `k-j-kim` / `kj-kim_sfemu`.

You also need the local AFV `.vsix` at the path in `LOCAL_VSIX` (in
`repos.conf`) — update that path for your machine.

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
