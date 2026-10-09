#!/usr/bin/env bash
# Runs the Modernisation Platform reusable-code-quality baseline (MegaLinter) locally in Docker.
#
# Usage (from inside a git repo):
#   setup-local-lint.sh            install the pre-push hook (idempotent), then exit
#   setup-local-lint.sh --run      run the lint now
#   setup-local-lint.sh --uninstall  remove the hook
#
# Environment overrides:
#   MEGALINTER_CONFIG   path to a repo .mega-linter.yml (relative to repo root)
#   DISABLE_LINTERS     comma separated linters to skip, e.g. REPOSITORY_CHECKOV,REPOSITORY_SEMGREP
#   VALIDATE_ALL_CODEBASE  "true" to lint everything rather than changed files
#   LINT_INPUT_<NAME>   any other workflow input, e.g. LINT_INPUT_CHECKOV_ARGUMENTS="--skip-check CKV_AWS_126"
#   WORKFLOW_REF        branch/tag of modernisation-platform-github-actions to read the baseline from (default: main)
set -euo pipefail

MARKER="# managed-by: setup-local-lint"

# The linter baseline and MegaLinter version are read from the upstream reusable workflow.
WORKFLOW_REF="${WORKFLOW_REF:-main}"
WORKFLOW_URL="https://raw.githubusercontent.com/ministryofjustice/modernisation-platform-github-actions/${WORKFLOW_REF}/.github/workflows/reusable-code-quality.yml"
CACHE_DIR="${HOME}/.cache/local-lint"
WORKFLOW_CACHE="${CACHE_DIR}/reusable-code-quality-${WORKFLOW_REF//\//_}.yml"

die() { echo "error: $*" >&2; exit 1; }

# Sets IMAGE and BASELINE from the remote workflow, falling back to the last cached copy if offline.
load_remote_config() {
  mkdir -p "$CACHE_DIR"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL --max-time 20 "$WORKFLOW_URL" -o "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$WORKFLOW_CACHE"
  else
    rm -f "$tmp"
    [ -f "$WORKFLOW_CACHE" ] || die "couldn't download $WORKFLOW_URL and no cached copy exists."
    echo "warning: using cached workflow (download failed): $WORKFLOW_CACHE" >&2
  fi

  # BASELINE_LINTERS is a folded YAML block: join its lines until the next key.
  BASELINE="$(awk '
    /BASELINE_LINTERS: *>-/ { grab = 1; next }
    grab && /^[[:space:]]+[A-Z0-9_,]+,?[[:space:]]*$/ { gsub(/[[:space:]]/, ""); out = out $0; next }
    grab { exit }
    END { print out }
  ' "$WORKFLOW_CACHE")"
  [ -n "$BASELINE" ] || die "couldn't parse BASELINE_LINTERS from the workflow; its format may have changed."

  # The version tag is in the comment after the pinned action, e.g. "oxsecurity/megalinter@<sha> # v10.1.0".
  local tag
  tag="$(grep -Eo 'oxsecurity/megalinter@[0-9a-f]+ +# +v[0-9][0-9.]*' "$WORKFLOW_CACHE" | head -n1 | grep -Eo 'v[0-9][0-9.]*$' || true)"
  [ -n "$tag" ] || die "couldn't parse the MegaLinter version from the workflow."
  IMAGE="ghcr.io/oxsecurity/megalinter:${tag}"
}

check_dependencies() {
  command -v git >/dev/null 2>&1 || die "git is not installed."
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "run this from inside a git repository."
  command -v curl >/dev/null 2>&1 || die "curl is not installed."
  command -v python3 >/dev/null 2>&1 || die "python3 is not installed (xcode-select --install)."
  command -v docker >/dev/null 2>&1 || die "docker is not installed (brew install --cask docker)."
  docker info >/dev/null 2>&1 || die "docker is installed but not running. Start Docker Desktop and retry."
}

run_lint() {
  check_dependencies
  local repo_root cache_dir
  repo_root="$(git rev-parse --show-toplevel)"
  cache_dir="${HOME}/.cache/grype"
  mkdir -p "$cache_dir"

  load_remote_config
  echo "Using $IMAGE with linters from workflow ref '$WORKFLOW_REF'"

  local rendered line
  rendered="$(BASELINE_LINTERS="$BASELINE" render_env)" || die "couldn't translate the upstream MegaLinter settings."
  local env_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && env_args+=(-e "$line")
  done <<< "$rendered"

  # MegaLinter diffs against origin to find changed files, as in CI.
  git fetch origin --quiet 2>/dev/null || echo "warning: git fetch failed; changed-file scope may differ from CI." >&2

  # Pull only when the image is missing so pushes stay fast.
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "Pulling $IMAGE (one-off, several GB)..."
    docker pull "$IMAGE"
  }

  docker run --rm \
    -v "$repo_root:/tmp/lint" \
    -v "$cache_dir:/github/home/.cache/grype" \
    -e DEFAULT_WORKSPACE=/tmp/lint \
    "${env_args[@]}" \
    "$IMAGE"
}

# Translates the upstream "Run MegaLinter" env block into KEY=VALUE lines by evaluating its GitHub
# expressions as a pull_request run. Nothing is hardcoded, so upstream changes flow through automatically.
render_env() {
  python3 - "$WORKFLOW_CACHE" <<'PY'
import os, re, sys

# Local-only differences from CI. None removes the setting.
OVERRIDES = {
    "GITHUB_TOKEN": None,            # no credentials locally
    "GRYPE_DB_AUTO_UPDATE": None,    # CI pre-populates the DB; locally let Grype update it
    "REPORTERS": "",                 # don't write reports into the repo
    "SARIF_REPORTER": "false",
    "REPORT_OUTPUT_FOLDER": "/tmp/megalinter-reports",  # inside the container; linters write generated config here
    "APPLY_FIXES": "none",           # report only, never modify files
}
# inputs.<name> comes from LINT_INPUT_<NAME>, or these older aliases.
ALIASES = {
    "megalinter_config": "MEGALINTER_CONFIG",
    "disable_linters": "DISABLE_LINTERS",
    "validate_all_codebase": "VALIDATE_ALL_CODEBASE",
}

def fail(msg):
    sys.exit("error: " + msg)

class Ctx:
    def __init__(self, data):
        self._d = data
    def __getattr__(self, name):
        v = self._d.get(name, "")
        return Ctx(v) if isinstance(v, dict) else v

class Inputs:
    def __getattr__(self, name):
        if name == "apply_fixes":
            return False
        return os.environ.get("LINT_INPUT_" + name.upper()) or os.environ.get(ALIASES.get(name, "_UNSET_"), "")

def fmt(template, *args):
    return re.sub(r"\{(\d+)\}", lambda m: str(args[int(m.group(1))]), template)

github = Ctx({
    "event_name": "pull_request",
    "ref": "refs/pull/0/merge",
    "ref_name": "local",
    "token": "",
    "event": {"pull_request": {"head": {"repo": {"full_name": ""}}}, "repository": {"private": True}},
})
scope = {
    "__builtins__": {},
    "github": github,
    "inputs": Inputs(),
    "env": Ctx({"BASELINE_LINTERS": os.environ.get("BASELINE_LINTERS", "")}),
    "format": fmt,
    "True": True, "False": False, "None": None,
}

def to_python(expr):
    parts = re.split(r"('(?:[^']|'')*')", expr)
    out = []
    for i, p in enumerate(parts):
        if i % 2:
            out.append(repr(p[1:-1].replace("''", "'")))
            continue
        p = p.replace("&&", " and ").replace("||", " or ")
        p = re.sub(r"!(?!=)", " not ", p)
        p = re.sub(r"\btrue\b", "True", p)
        p = re.sub(r"\bfalse\b", "False", p)
        p = re.sub(r"\bnull\b", "None", p)
        out.append(p)
    return "".join(out)

def evaluate(expr, key):
    try:
        v = eval(to_python(expr.strip()), scope)
    except Exception as e:
        fail("can't evaluate the expression for %s (%s): %s" % (key, e, expr.strip()))
    if isinstance(v, bool):
        return "true" if v else "false"
    return "" if v is None else str(v)

lines = open(sys.argv[1]).read().splitlines()
step = inenv = False
items = []
for line in lines:
    if "- name: Run MegaLinter" in line:
        step = True
        continue
    if step and re.match(r"^      - name:", line):
        break
    if step and re.match(r"^        env:", line):
        inenv = True
        continue
    if step and inenv:
        if not line.strip() or re.match(r"^\s*#", line):
            continue
        m = re.match(r"^          ([A-Z0-9_]+):\s*(.*)$", line)
        if m:
            items.append((m.group(1), m.group(2).strip()))
        elif not line.startswith("          "):
            break

if not items:
    fail("couldn't find the MegaLinter env block; the upstream layout may have changed.")

result = {}
for key, raw in items:
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        raw = raw[1:-1]
    result[key] = re.sub(r"\$\{\{(.*?)\}\}", lambda m: evaluate(m.group(1), key), raw)

for key, value in OVERRIDES.items():
    if value is None:
        result.pop(key, None)
    else:
        result[key] = value

for key, value in result.items():
    print("%s=%s" % (key, value))
PY
}

hook_path() {
  # Respects core.hooksPath and worktrees.
  local p
  p="$(git rev-parse --git-path hooks/pre-push)"
  case "$p" in /*) echo "$p" ;; *) echo "$(git rev-parse --show-toplevel)/$p" ;; esac
}

install_hook() {
  check_dependencies
  local hook script_path
  hook="$(hook_path)"
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  if [ -f "$hook" ] && ! grep -q "$MARKER" "$hook"; then
    die "an existing pre-push hook is present at $hook and isn't managed by this script. Merge manually."
  fi

  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
$MARKER
exec "$script_path" --run
EOF
  chmod +x "$hook"
  echo "Installed pre-push hook: $hook"
  echo "Pushes from the terminal or VS Code Source Control will now run the lint. Bypass with: git push --no-verify"
}

uninstall_hook() {
  local hook
  hook="$(hook_path)"
  if [ -f "$hook" ] && grep -q "$MARKER" "$hook"; then
    rm "$hook"
    echo "Removed $hook"
  else
    echo "No managed hook found."
  fi
}

case "${1:-}" in
  --run) run_lint ;;
  --uninstall) uninstall_hook ;;
  ""|--install) install_hook ;;
  -h|--help) sed -n '2,13p' "$0" ;;
  *) die "unknown option: $1 (use --run, --install, --uninstall)" ;;
esac
