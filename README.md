# code-quality-pre-commit-checks

Run the Modernisation Platform **Reusable Code Quality** workflow locally, in Docker, as a Git
**pre-push hook**, so lint and security problems are caught from your terminal or VS Code *before*
you push and open a pull request.

The upstream workflow is
[`reusable-code-quality.yml`](https://github.com/ministryofjustice/modernisation-platform-github-actions/blob/main/.github/workflows/reusable-code-quality.yml).
It runs [MegaLinter](https://megalinter.io) with an opinionated baseline of linters. This project
runs the **same MegaLinter image, the same linters and the same settings** on your machine.

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
  - [`setup-local-lint.sh`](#setup-local-lintsh)
  - [`install-local-lint.sh`](#install-local-lintsh)
- [Configuration](#configuration)
- [VS Code](#vs-code)
- [What runs locally vs in CI](#what-runs-locally-vs-in-ci)
- [Keeping in step with upstream](#keeping-in-step-with-upstream)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Uninstalling](#uninstalling)
- [FAQ](#faq)

## How it works

```text
git push
   │
   ▼
.git/hooks/pre-push            (installed by setup-local-lint.sh)
   │  exec
   ▼
setup-local-lint.sh --run
   ├─ 1. checks git, curl, python3, docker (and that Docker is running)
   ├─ 2. downloads reusable-code-quality.yml from GitHub (cached for offline use)
   ├─ 3. reads the MegaLinter version and the BASELINE_LINTERS list from it
   ├─ 4. translates the workflow's "Run MegaLinter" env block into docker -e settings
   ├─ 5. runs git fetch origin (so "changed files" matches CI)
   └─ 6. docker run ghcr.io/oxsecurity/megalinter:<version>  against your repo
          │
          ├─ exit 0 → push continues
          └─ exit 1 → push is blocked and the findings are printed
```

Nothing about the lint configuration is hardcoded. The linter list, the MegaLinter version and every
per-linter setting come from the upstream workflow on each run. When upstream changes, your local
run changes with it, with no edits to this repository.

The upstream settings are GitHub Actions expressions (for example
`${{ github.event_name == 'pull_request' && 'file' || 'project' }}`). The script contains a small
evaluator that resolves them as a **pull request** run, which is what you're preparing when you push.

## Repository layout

```text
code-quality-pre-commit-checks/
├── README.md
└── bin/
    ├── setup-local-lint.sh      # installs/removes the hook and runs the lint (the main script)
    └── install-local-lint.sh    # installs/removes the hook in one or many repos
```

Keep both scripts in the same directory. `install-local-lint.sh` finds `setup-local-lint.sh` next to
itself.

## Requirements

| Tool | Why | Install (macOS) |
|---|---|---|
| `git` | hooks, changed-file detection | `xcode-select --install` |
| `docker` (running) | runs MegaLinter | `brew install --cask docker`, then start Docker Desktop |
| `curl` | downloads the upstream workflow | included with macOS |
| `python3` | evaluates the workflow's expressions | `xcode-select --install` |

The scripts check these on every run and stop with a clear message if one is missing, so there is no
separate setup step to remember.

Also needed:
- Network access to `raw.githubusercontent.com` and `ghcr.io` (the first run only needs `ghcr.io` once).
- Several GB of disk space for the MegaLinter image.

## Quick start

```bash
# 1. Get the scripts somewhere permanent
git clone git@github.com:mikereiddigital/code-quality-pre-commit-checks.git ~/git/code-quality-pre-commit-checks

# 2. Install the hook in a repo
cd ~/git/<your-repo>
~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh

# 3. Push as normal; the lint runs first
git push
```

The first run pulls the MegaLinter image (several GB, a few minutes). Later runs are much quicker.

To try it without pushing:

```bash
~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --run
```

> **Important:** the hook stores the *absolute path* of `setup-local-lint.sh`. Decide where this
> repository lives before installing. If you move it, re-run the install command in each repo.

## Usage

### `setup-local-lint.sh`

Run from inside a Git repository.

| Command | Effect |
|---|---|
| `setup-local-lint.sh` | Install the pre-push hook (same as `--install`). Safe to re-run. |
| `setup-local-lint.sh --install` | Install the pre-push hook. |
| `setup-local-lint.sh --run` | Run the lint now. This is what the hook calls. |
| `setup-local-lint.sh --uninstall` | Remove the hook, only if this script installed it. |
| `setup-local-lint.sh --help` | Show the header documentation. |

Hook behaviour:
- It respects `core.hooksPath` and Git worktrees.
- It refuses to overwrite an existing `pre-push` hook it doesn't manage (for example one from Husky or
  pre-commit). It tells you to merge manually.
- Re-running the install is idempotent.

Run behaviour:
- The lint is **report-only**. It never edits, formats or commits files. (CI can auto-commit
  formatting fixes; locally this is disabled.)
- Only **changed files** are linted by default, as in CI on a pull request. The comparison is against
  `origin`, so the script runs `git fetch origin` first.
- Reports are not written into your repository.
- Exit code `0` means the push proceeds. Any other exit code blocks it.

### `install-local-lint.sh`

Install or remove the hook in several repositories at once.

```bash
# specific repositories
install-local-lint.sh ~/git/repo-a ~/git/repo-b

# every Git repository directly under a directory
install-local-lint.sh --all ~/git

# remove the hook again
install-local-lint.sh --uninstall --all ~/git
```

It runs `setup-local-lint.sh` inside each repo, carries on if one fails, then prints a summary and
exits non-zero if any repository failed. Typical failures:
- the path isn't a Git repository
- the repository already has a pre-push hook this project doesn't manage

`--all` only looks one level deep, so repositories nested further down are not found.

## Configuration

Configuration is by environment variables on the command that triggers the lint.

| Variable | Purpose | Example |
|---|---|---|
| `DISABLE_LINTERS` | Comma separated linters to skip | `DISABLE_LINTERS=REPOSITORY_CHECKOV,REPOSITORY_SEMGREP` |
| `VALIDATE_ALL_CODEBASE` | `true` lints every file, not just changed ones | `VALIDATE_ALL_CODEBASE=true` |
| `MEGALINTER_CONFIG` | Repo-specific `.mega-linter.yml`, relative to the repo root | `MEGALINTER_CONFIG=.github/linters/.mega-linter.yml` |
| `WORKFLOW_REF` | Branch or tag of `modernisation-platform-github-actions` to read settings from (default `main`) | `WORKFLOW_REF=<tag>` |
| `LINT_INPUT_<NAME>` | Any other input of the upstream workflow, upper-cased | `LINT_INPUT_CHECKOV_ARGUMENTS="--skip-check CKV_AWS_126"` |

`LINT_INPUT_<NAME>` maps to the workflow's `inputs.<name>`. Useful ones:

| Variable | Upstream input |
|---|---|
| `LINT_INPUT_ENABLE_LINTERS` | `enable_linters` (extra linters on top of the baseline) |
| `LINT_INPUT_FILTER_REGEX_EXCLUDE` | `filter_regex_exclude` |
| `LINT_INPUT_CHECKOV_ARGUMENTS` | `checkov_arguments` |
| `LINT_INPUT_TFLINT_ARGUMENTS` | `tflint_arguments` |
| `LINT_INPUT_ACTION_ACTIONLINT_FILTER_REGEX_EXCLUDE` | `action_actionlint_filter_regex_exclude` |

Examples:

```bash
# one-off, skip slow scanners for this push
DISABLE_LINTERS=REPOSITORY_CHECKOV,REPOSITORY_SEMGREP git push

# lint the whole repository now
VALIDATE_ALL_CODEBASE=true ~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --run

# match what a repo passes to the workflow in CI
LINT_INPUT_TFLINT_ARGUMENTS="--disable-rule=terraform_unused_declarations" \
  ~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --run
```

To make settings permanent for a repo, set the same options in the repo's workflow call, mirror them
in a `.mega-linter.yml`, and point `MEGALINTER_CONFIG` at it. Export variables from your shell profile
if you want them for every push (VS Code inherits them only if it was launched from that shell, for
example with `code .`).

### Local-only differences from CI

A short table inside `setup-local-lint.sh` (`OVERRIDES`) adjusts things that make no sense outside
GitHub Actions. These are the only values that are not taken from upstream:

| Setting | Local value | Reason |
|---|---|---|
| `GITHUB_TOKEN` | removed | no credentials locally |
| `GRYPE_DB_AUTO_UPDATE` | removed | CI pre-downloads the DB; locally Grype updates itself |
| `APPLY_FIXES` | `none` | report only, never modify files |
| `REPORTERS`, `SARIF_REPORTER` | off | don't produce SARIF or other reports |
| `REPORT_OUTPUT_FOLDER` | `/tmp/megalinter-reports` | inside the container so the repo stays clean |

## VS Code

VS Code's Source Control **Push** and **Sync** run Git hooks, so the hook works with no extra setup.

- Output from a failed push appears in **View → Output → Git** and in the error notification.
- To lint on demand, add a task in `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Lint (MegaLinter, same as CI)",
      "type": "shell",
      "command": "~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --run",
      "problemMatcher": []
    }
  ]
}
```

Run it with **Terminal → Run Task**.

If the hook fails inside VS Code with "command not found" (`docker`, `python3`), VS Code probably has
a different `PATH` from your terminal. Launch it from a terminal with `code .`, or make sure Docker
Desktop's CLI is on the default path.

## What runs locally vs in CI

| Part of the workflow | Locally |
|---|---|
| MegaLinter baseline (actionlint, zizmor, shellcheck, hadolint, editorconfig-checker, prettier for JSON/YAML, markdownlint, betterleaks, checkov, grype, semgrep, terraform fmt, tflint, yamllint) | **Yes**, same image version and settings |
| Linter list and MegaLinter version | **Yes**, read from upstream each run |
| Auto-commit of formatting fixes | No (report only) |
| SARIF upload to the GitHub Security tab | No |
| Dependency Review | No |
| CodeQL | No |
| Harden Runner | No |

The exact set of linters is whatever upstream's `BASELINE_LINTERS` says at the time. Linters with no
matching files, or no config they need (for example Semgrep without a ruleset), are skipped by
MegaLinter itself, in CI and locally alike.

## Keeping in step with upstream

Each run downloads the latest workflow, so there's normally nothing to do. Details:

- **Offline:** the last downloaded copy is cached in `~/.cache/local-lint/` and used with a warning.
  If there's no cached copy, the run stops with an error.
- **Pin to a version:** set `WORKFLOW_REF` to a tag or branch to freeze or test a particular upstream
  state.
- **New upstream settings or linters:** picked up automatically.
- **Upstream uses an expression the evaluator can't handle:** the run stops with an error naming the
  setting. It never runs with wrong values. In that case extend the evaluator (the `render_env`
  function in `setup-local-lint.sh`).
- **Upstream restructures the workflow file** (renames the step, changes how `BASELINE_LINTERS` is
  written, or moves the version comment): parsing fails with a clear error and the lint, and so the
  push, is blocked until the script is adjusted. You can bypass it with `git push --no-verify`.

Cached data lives in:

| Path | Contents |
|---|---|
| `~/.cache/local-lint/` | cached copy of the upstream workflow |
| `~/.cache/grype/` | Grype vulnerability database (shared between runs and repos) |
| Docker image `ghcr.io/oxsecurity/megalinter:<version>` | MegaLinter; a new version is pulled when upstream bumps it |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `docker is installed but not running` | Start Docker Desktop and push again. |
| `an existing pre-push hook is present ... not managed by this script` | Another tool owns the hook (Husky, pre-commit). Call `setup-local-lint.sh --run` from that tool's hook instead. |
| `couldn't download ... and no cached copy exists` | No network on the very first run. Reconnect and retry. |
| `couldn't parse BASELINE_LINTERS` / `couldn't find the MegaLinter env block` | Upstream changed the workflow's layout. Pin `WORKFLOW_REF` to an older tag and adjust the parsing in the script. |
| `can't evaluate the expression for <KEY>` | Upstream used a GitHub expression feature the evaluator lacks. Extend `render_env`. |
| Hook runs the old script path after moving this repo | Hooks store an absolute path. Re-run the install in each repo. |
| Very slow first run | The first run pulls the multi-GB image and the Grype database. Later runs reuse both. |
| "Matching files: 0" / few linters run | Nothing has changed against `origin`. Try `VALIDATE_ALL_CODEBASE=true`. |
| Changed files differ from CI | Make sure `origin` is reachable. The script runs `git fetch origin` and only warns if it fails. |
| A finding that you accept | Add it to the repo's own config (for example `.checkov.yml`, `.yamllint`, `.mega-linter.yml`), as you would for CI. |
| Need to push now regardless | `git push --no-verify`. CI remains the enforced check. |

To see everything MegaLinter prints, run `setup-local-lint.sh --run` directly instead of pushing.

## Limitations

- **Not identical to CI in every respect.** CodeQL, Dependency Review, Harden Runner and the SARIF
  upload only exist on GitHub. Grype is advisory on pull requests in CI, and the same is true here.
- **Changed-file scope depends on `origin`.** It follows MegaLinter's own diff logic against the
  remote default branch.
- **Hooks are advisory.** Anyone can bypass them with `--no-verify`. Keep the CI workflow as the
  enforced gate.
- **Hooks are per clone.** Each clone of each repo needs the install step once.
- **The expression evaluator covers what the upstream workflow currently uses:** `&&`, `||`, `!`,
  `==`, `!=`, `format()`, `inputs.*`, `github.*` and `env.*`. It is intentionally small.
- **Absolute path in the hook.** Moving this repository requires re-installing.
- **Developed and tested on macOS.** The scripts use Bash 3.2-compatible syntax, but only macOS with
  Docker Desktop has been tested. Install hints are macOS-specific.
- **Everything is read from the network on each run** (a single small file download, with the
  fallback above). Set `WORKFLOW_REF` to a tag if you want stability.

## Uninstalling

```bash
# one repo
cd ~/git/<your-repo> && ~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --uninstall

# many repos
~/git/code-quality-pre-commit-checks/bin/install-local-lint.sh --uninstall --all ~/git

# optional: free disk space
rm -rf ~/.cache/local-lint ~/.cache/grype
docker image rm ghcr.io/oxsecurity/megalinter:<version>
```

Only hooks created by this project (marked `# managed-by: setup-local-lint`) are removed.

## FAQ

**Why a pre-push hook and not pre-commit?**
The full MegaLinter run takes from tens of seconds to a couple of minutes, which is too slow to run on
every commit but right for a push. It also mirrors the point at which CI would otherwise run.

**Does it change my files?**
No. `APPLY_FIXES` is forced to `none`, so it reports problems only. If CI would auto-format your
files, run the relevant formatter yourself (for example `terraform fmt`, `prettier --write`).

**Can it use the pre-commit framework?**
Yes, as a local hook: set `entry: ~/git/code-quality-pre-commit-checks/bin/setup-local-lint.sh --run`,
`language: system`, `pass_filenames: false`, `stages: [pre-push]` in `.pre-commit-config.yaml`. Don't
also run the install command, to avoid two hooks competing.

**Does it need a GitHub token?**
No. Nothing is posted to GitHub, and the token is removed from the container environment.

**Which linters run for my repo?**
Upstream's baseline, filtered by what MegaLinter finds in your changed files. Run with
`VALIDATE_ALL_CODEBASE=true` to see the maximum set.

**How do I run only one linter?**
Disable the others with `DISABLE_LINTERS`, or run MegaLinter's own runner with `ENABLE_LINTERS=<KEY>`.

**Is it safe to run on any repository?**
It mounts the repository into a container as read-write (MegaLinter needs this) but is configured to
report only. It doesn't push, commit or contact GitHub beyond downloading the workflow file.
