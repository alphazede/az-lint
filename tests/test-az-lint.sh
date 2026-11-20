#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AZ_LINT="$ROOT/az-lint"
PRE_PUSH="$ROOT/pre-push"
INSTALL_HOOK="$ROOT/install-hook"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/az-lint-selftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export AZ_LINT_LOG_DIR="$WORK/logs"
export GIT_CONFIG_GLOBAL="$WORK/global" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$AZ_LINT_LOG_DIR"

failures=0
pass_count=0

ok() {
	printf 'ok   %s\n' "$1"
	pass_count=$((pass_count + 1))
}

fail() {
	printf 'FAIL %s: %s\n' "$1" "$2"
	if [[ -n "${3:-}" && -f "$3" ]]; then
		printf '     --- output tail ---\n'
		tail -n 25 "$3" | sed 's/^/     | /'
	fi
	failures=$((failures + 1))
}

assert_rc() {
	local name="$1" want="$2" got="$3" log="$4"
	if [[ "$got" == "$want" ]]; then
		ok "$name"
	else
		fail "$name" "expected exit $want, got $got" "$log"
	fi
}

assert_grep() {
	local name="$1" pattern="$2" file="$3"
	if grep -Eq "$pattern" "$file"; then
		ok "$name"
	else
		fail "$name" "pattern '$pattern' not found in $file" "$file"
	fi
}

assert_tool_status() {
	local scenario="$1" status="$2" output="$3"
	shift 3
	local tool
	for tool in "$@"; do
		assert_grep "$scenario: $tool reports $status" "^${tool}[[:space:]]+${status}[[:space:]]" "$output"
	done
}

LANGUAGE_TOOLS=(
	cargo-fmt cargo-clippy ruff-check ruff-format shellcheck shfmt actionlint
	yamllint biome tsc sqlfluff verible-lint verible-format verilator clang-format cppcheck
)
ALL_TOOLS=("${LANGUAGE_TOOLS[@]}" gitleaks semgrep)

# Keep runtime utilities available while hiding every linter for MISSING cases.
RESTRICTED_BIN="$WORK/restricted-bin"
STUB_BIN="$WORK/stub-bin"
mkdir -p "$RESTRICTED_BIN" "$STUB_BIN"
for cmd in bash cat chmod cp date dirname env git git-receive-pack grep ln mkdir mktemp mv python3 rm sed sh stat tail tar touch; do
	p=$(type -P "$cmd") || {
		printf 'FATAL: self-test requires %s\n' "$cmd" >&2
		exit 2
	}
	ln -s "$p" "$RESTRICTED_BIN/$cmd"
done

# Force stubs in CI even when the runner image ships with real linters.
if [[ "${AZ_LINT_STUBS_ONLY:-0}" == 1 ]]; then
	export PATH="$RESTRICTED_BIN"
fi

# The stubs exercise runner dispatch on these fixtures when a linter is absent.
cat >"$STUB_BIN/lint-stub" <<'SH'
#!/usr/bin/env bash
tool=${0##*/}
case "$tool" in
  cargo)
    case "$1" in
      fmt) real_cargo=${SELFTEST_CARGO_FMT:-} ;;
      clippy) real_cargo=${SELFTEST_CARGO_CLIPPY:-} ;;
      *) exit 2 ;;
    esac
    if [[ -n "$real_cargo" ]]; then
      exec "$real_cargo" "$@"
    fi
    [[ "$2" == --version ]] && exit 0
    if bad_file=$(grep -l 'let unused=1' src/*.rs) && [[ -n "$bad_file" ]]; then
      if [[ "$1" == fmt ]]; then
        printf 'Diff in %s/%s:1:\n' "$PWD" "$bad_file"
        exit 1
      fi
      printf '{"reason":"compiler-message","message":{"level":"error","spans":[{"file_name":"%s","is_primary":true}],"rendered":"error: unused variable"}}\n' "$bad_file"
      exit 101
    fi
    ;;
  tsc)
    if grep -q 'wrong type' bad.ts 2>/dev/null; then
      printf "%s\n" "bad.ts(2,14): error TS2322: Type 'string' is not assignable to type 'number'."
      exit 2
    fi
    ;;
  gitleaks)
    for arg in "$@"; do
      case "$arg" in
        --log-opts=*) range=${arg#*=} ;;
        --gitleaks-ignore-path=*) ignore=${arg#*=} ;;
      esac
    done
    if [[ "$1" == dir ]]; then
      grep -Eq '^token = "ghp_[[:alnum:]]{36}"' "${!#}" && exit 1
    else
      [[ "$1" == git && -n "${range:-}" ]] || exit 2
      read -r -a log_opts <<<"$range"
      patch=$(git log -p "${log_opts[@]}" --) || exit 2
      if grep -Eq '^\+token = "ghp_[[:alnum:]]{36}"' <<<"$patch"; then
        if [[ ! -f "${ignore:-}" ]] || ! grep -q ':allowlisted.txt:github-pat:1$' "$ignore"; then
          exit 1
        fi
      fi
    fi
    ;;
  semgrep)
    for file in "$@"; do
      if [[ "$file" == *.py ]] && grep -q 'tempfile.mktemp()' "$file"; then
        printf 'az-python-unsafe-mktemp: %s\n' "$file"
        exit 1
      fi
    done
    ;;
  *)
    case "$tool" in
      ruff)
        if [[ "$1" == check && " $* " == *" --ignore=F401,I001 "* ]]; then
          exit 0
        fi
        if [[ "$1" == check ]]; then
          for file in "$@"; do
            if [[ "$file" == *.py && -f "$file" ]] && grep -qx 'import sys' "$file"; then
              if [[ ! -f .ruff.toml ]] || ! grep -q 'F401' .ruff.toml; then
                printf 'stub ruff import error: %s\n' "$file"
                exit 1
              fi
            fi
          done
        fi
        fixture=*.py
        ;;
      shellcheck|shfmt) fixture=*.sh ;;
      actionlint) fixture=*.yml ;;
      yamllint) fixture=*.yaml ;;
      biome) fixture=*.ts ;;
      sqlfluff) fixture=*.sql ;;
      verible-verilog-lint|verible-verilog-format|verilator) fixture=*.sv ;;
      clang-format|cppcheck) fixture=*.c ;;
      *) exit 2 ;;
    esac
    for file in "$@"; do
      if [[ "${file##*/}" == bad$fixture && -f "$file" ]]; then
        printf 'stub %s error: %s\n' "$tool" "$file" >&2
        exit 1
      fi
    done
    ;;
esac
exit 0
SH
chmod +x "$STUB_BIN/lint-stub"

REAL_TOOLS=()
STUBBED_TOOLS=()
for tool in ruff shellcheck shfmt actionlint yamllint biome tsc sqlfluff \
	verible-verilog-lint verible-verilog-format verilator clang-format cppcheck gitleaks semgrep; do
	if type -P "$tool" >/dev/null; then
		REAL_TOOLS+=("$tool")
	else
		ln -s lint-stub "$STUB_BIN/$tool"
		STUBBED_TOOLS+=("$tool")
	fi
done

# Cargo can have one component installed without the other.
unset SELFTEST_CARGO_FMT SELFTEST_CARGO_CLIPPY
cargo_path=$(type -P cargo) || cargo_path=
for sub in fmt clippy; do
	if [[ -n "$cargo_path" ]] && "$cargo_path" "$sub" --version >/dev/null 2>&1; then
		export "SELFTEST_CARGO_${sub^^}=$cargo_path"
		REAL_TOOLS+=("cargo-$sub")
	else
		STUBBED_TOOLS+=("cargo-$sub")
	fi
done
if [[ -z "${SELFTEST_CARGO_FMT:-}" || -z "${SELFTEST_CARGO_CLIPPY:-}" ]]; then
	ln -s lint-stub "$STUB_BIN/cargo"
fi

printf 'Real tools: %s\n' "${REAL_TOOLS[*]:-none}"
printf 'Stubbed tools: %s\n' "${STUBBED_TOOLS[*]:-none}"
export PATH="$STUB_BIN:$PATH"
TSC=$(type -P tsc)
install_tsc() {
	printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$TSC" >"$1/tsc"
	chmod +x "$1/tsc"
}

# Build a throwaway repository with a bare remote and unchanged violations on main.
REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
git init --bare -qb main "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@localhost
git -C "$REPO" branch -M main

# Unchanged violating files committed on main (must NOT block subsequent changes).
cat >"$REPO/unchanged_bad.py" <<'PY'
import sys
x=1
PY
cat >"$REPO/unchanged_bad.sh" <<'SH'
#!/usr/bin/env bash
echo $1
SH
cat >"$REPO/unchanged_bad.c" <<'C'
int unchanged_bad(void) { int u; return u; }
C
cat >"$REPO/.semgrep.yml" <<'YML'
rules:
  - id: az-python-unsafe-mktemp
    languages: [python]
    severity: ERROR
    message: Use tempfile.mkstemp() to create a temporary file.
    pattern: tempfile.mktemp(...)
YML
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base with unchanged violations"
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q -u origin main

# 3a. SKIP when nothing matches (only .txt changed), plus unchanged violations ignored.
git -C "$REPO" checkout -q -b feat/skip
printf 'plain note\n' >"$REPO/notes.txt"
git -C "$REPO" add notes.txt
git -C "$REPO" commit -q -m "txt only"
"$AZ_LINT" --repo "$REPO" --changed main >"$WORK/skip.out" 2>&1
rc=$?
assert_rc "SKIP-only txt change passes (unchanged violations ignored)" 0 "$rc" "$WORK/skip.out"
assert_tool_status "txt-only change" SKIP "$WORK/skip.out" "${LANGUAGE_TOOLS[@]}"
"$AZ_LINT" --repo "$REPO" --pre-push </dev/null >"$WORK/no-refs.out" 2>&1
rc=$?
assert_rc "pre-push without refs exits 0" 0 "$rc" "$WORK/no-refs.out"
assert_tool_status "pre-push without refs" SKIP "$WORK/no-refs.out" gitleaks semgrep
assert_grep "gitleaks reports PASS on txt-only change" "^gitleaks[[:space:]]+PASS" "$WORK/skip.out"
assert_grep "log path printed" "^log: " "$WORK/skip.out"

# 3b. Deleted violating file is skipped.
git -C "$REPO" checkout -q -b feat/delete main
git -C "$REPO" rm -q unchanged_bad.py
git -C "$REPO" commit -q -m "delete bad python file"
"$AZ_LINT" --repo "$REPO" --changed main >"$WORK/delete.out" 2>&1
rc=$?
assert_rc "deleted violating file is skipped and passes" 0 "$rc" "$WORK/delete.out"
assert_grep "ruff-check skips deleted file" "^ruff-check[[:space:]]+SKIP" "$WORK/delete.out"

# 3c. All-language VIOLATIONS branch -> every language tool reports FAIL.
git -C "$REPO" checkout -q -b feat/violations main
mkdir -p "$REPO/rust_ws/src" "$REPO/.github/workflows" "$REPO/web"
cat >"$REPO/rust_ws/Cargo.toml" <<'TOML'
[package]
name = "sample"
version = "0.1.0"
edition = "2021"
TOML
cat >"$REPO/rust_ws/Cargo.lock" <<'TOML'
version = 3

[[package]]
name = "sample"
version = "0.1.0"
TOML
cat >"$REPO/rust_ws/src/lib.rs" <<'RS'
pub fn bad( x:i32 )->i32{let unused=1;x}
RS

cat >"$REPO/bad.py" <<'PY'
import os
import tempfile
def f():
  return tempfile.mktemp()
PY
cat >"$REPO/bad.sh" <<'SH'
#!/usr/bin/env bash
if [ "$#" -gt 0 ];then
echo $1
fi
SH
cat >"$REPO/.github/workflows/bad.yml" <<'YML'
name: bad
on: push
jobs:
  j:
    runs-on: ubuntu-26.04
    steps:
      - unknown_field: true
YML
cat >"$REPO/bad.yaml" <<'YML'
---
key: first
key: second
YML
cat >"$REPO/web/package.json" <<'JSON'
{"name":"web","scripts":{"typecheck":"tsc --noEmit"}}
JSON
cat >"$REPO/web/bad.ts" <<'TS'
debugger;
export const x: number = "wrong type";
TS
printf '{}\n' >"$REPO/web/tsconfig.json"
mkdir -p "$REPO/web/node_modules/.bin"
printf '/web/node_modules/\n' >>"$REPO/.git/info/exclude"
install_tsc "$REPO/web/node_modules/.bin"
cat >"$REPO/bad.sql" <<'SQL'
SELECT  a,b FROM sample;
SQL
cat >"$REPO/bad.sv" <<'SV'
module wrong_name(input logic [3:0] a, output logic [1:0] b);
  assign b = a;
endmodule
SV
cat >"$REPO/bad.c" <<'C'
int bad_c(void) { int u; return u; }
C
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "all-language violations"

"$AZ_LINT" --repo "$REPO" --changed main >"$WORK/viol.out" 2>&1
rc=$?
assert_rc "all-language violations exit 1" 1 "$rc" "$WORK/viol.out"
assert_tool_status "violation" FAIL "$WORK/viol.out" "${LANGUAGE_TOOLS[@]}" semgrep
assert_grep "semgrep prints advisory finding" "az-python-unsafe-mktemp" "$WORK/viol.out"

# 3d. .az-lint.toml overrides: disable cppcheck, exclude bad.c/bad.py, ignore F401.
cat >"$REPO/.az-lint.toml" <<'TOML'
exclude = ["bad.c", "bad.sv", "rust_ws/**", "bad.sh", "bad.yaml", "web/**", "bad.sql", ".github/**"]

[tools]
cppcheck = false

[tools.ruff-check]
args = ["--ignore=F401,I001"]
TOML
git -C "$REPO" add .az-lint.toml
git -C "$REPO" commit -q -m "configure .az-lint.toml"
"$AZ_LINT" --repo "$REPO" --changed main >"$WORK/toml.out" 2>&1
rc=$?
assert_rc ".az-lint.toml keeps unignored ruff-format FAIL" 1 "$rc" "$WORK/toml.out"
assert_grep ".az-lint.toml disables cppcheck (SKIP)" "^cppcheck[[:space:]]+SKIP[[:space:]]+disabled" "$WORK/toml.out"
assert_grep ".az-lint.toml args ignore F401 (ruff-check PASS)" "^ruff-check[[:space:]]+PASS" "$WORK/toml.out"
assert_tool_status ".az-lint.toml keeps ruff-format enabled" FAIL "$WORK/toml.out" ruff-format

# 3e. All-language CLEAN branch -> PASS across every tool, and verify speed < 60s.
git -C "$REPO" checkout -q -b feat/clean main
# Both Rust cases use the same dependency-free manifest and lockfile.
git -C "$REPO" restore --source=feat/violations -- rust_ws/Cargo.toml rust_ws/Cargo.lock
mkdir -p "$REPO/rust_ws/src" "$REPO/.github/workflows" "$REPO/web"
cat >"$REPO/rust_ws/src/lib.rs" <<'RS'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
RS

cat >"$REPO/clean.py" <<'PY'
"""Clean module."""


def add(a: int, b: int) -> int:
    return a + b
PY
cat >"$REPO/clean.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-ok}"
SH
cat >"$REPO/.github/workflows/clean.yml" <<'YML'
name: clean
on: push
jobs:
  j:
    runs-on: ubuntu-26.04
    steps:
      - run: echo ok
YML
cat >"$REPO/clean.yaml" <<'YML'
---
key: value
YML
cat >"$REPO/web/package.json" <<'JSON'
{"name":"web","scripts":{"typecheck":"tsc --noEmit"}}
JSON
cat >"$REPO/web/clean.ts" <<'TS'
export const x = 1;
TS
printf '{}\n' >"$REPO/web/tsconfig.json"
mkdir -p "$REPO/web/node_modules/.bin"
printf '/web/node_modules/\n' >>"$REPO/.git/info/exclude"
install_tsc "$REPO/web/node_modules/.bin"
cat >"$REPO/clean.sql" <<'SQL'
SELECT 1;
SQL
cat >"$REPO/clean.sv" <<'SV'
module clean (
    input  logic a,
    output logic b
);
  assign b = a;
endmodule
SV
cat >"$REPO/clean.c" <<'C'
int clean_c(void) { return 0; }
C
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "all-language clean"

t0_ns=$(date +%s%N)
"$AZ_LINT" --repo "$REPO" --changed main >"$WORK/clean.out" 2>&1
rc=$?
t1_ns=$(date +%s%N)
elapsed_ms=$(((t1_ns - t0_ns) / 1000000))
assert_rc "all-language clean exits 0" 0 "$rc" "$WORK/clean.out"
assert_tool_status "clean" PASS "$WORK/clean.out" "${ALL_TOOLS[@]}"
if ! grep -Eq "^semgrep[[:space:]]+PASS" "$WORK/clean.out"; then
	logf=$(sed -n 's/^log: //p' "$WORK/clean.out")
	[[ -f "$logf" ]] && sed -n '/=== semgrep/,/^===/p' "$logf" >&2
fi
if [[ "$elapsed_ms" -lt 60000 ]]; then
	ok "all-language run completed in ${elapsed_ms}ms (<60000ms)"
else
	fail "timing check" "took ${elapsed_ms}ms (>=60000ms)" "$WORK/clean.out"
fi
grep -E '^elapsed:' "$WORK/clean.out" || true

"$AZ_LINT" --untrusted --repo "$REPO" --changed main >"$WORK/clean-untrusted.out" 2>&1
assert_rc "10 all-language clean in untrusted mode" 0 "$?" "$WORK/clean-untrusted.out"
assert_tool_status "10 clean untrusted tools" PASS "$WORK/clean-untrusted.out" \
	ruff-check ruff-format shellcheck shfmt actionlint yamllint biome sqlfluff \
	verible-lint verible-format clang-format cppcheck gitleaks

mv "$REPO/web/node_modules" "$WORK/web-node-modules"
PATH="$RESTRICTED_BIN" "$AZ_LINT" --repo "$REPO" --changed main >"$WORK/missing.out" 2>&1
rc=$?
assert_rc "missing blocking tools exit 3" 3 "$rc" "$WORK/missing.out"
assert_tool_status "restricted PATH" MISSING "$WORK/missing.out" "${ALL_TOOLS[@]}"
mv "$WORK/web-node-modules" "$REPO/web/node_modules"

# 4. Pre-push hook installation, global git config untouched, worktree coverage,
# push refusal on violation, push success on clean, and gitleaks secret block.
GLOBAL_CFG_BEFORE=$(git config --global --list 2>/dev/null || true)
"$INSTALL_HOOK" "$REPO" >"$WORK/install.out" 2>&1
rc=$?
assert_rc "install-hook succeeds on repo" 0 "$rc" "$WORK/install.out"
GLOBAL_CFG_AFTER=$(git config --global --list 2>/dev/null || true)
if [[ "$GLOBAL_CFG_BEFORE" == "$GLOBAL_CFG_AFTER" ]]; then
	ok "install-hook leaves global git config unchanged"
else
	fail "global git config" "global git config changed" "$WORK/install.out"
fi

# Clean push succeeds on new branch.
git -C "$REPO" push -q -u origin feat/clean >"$WORK/push-clean.out" 2>&1
rc=$?
assert_rc "pre-push allows clean new-branch push" 0 "$rc" "$WORK/push-clean.out"

# Violating push is refused.
git -C "$REPO" checkout -q feat/violations
git -C "$REPO" reset -q --hard HEAD~1 # drop .az-lint.toml commit so violations fail
git -C "$REPO" push origin feat/violations >"$WORK/push-bad.out" 2>&1
assert_rc "pre-push refuses push with violations" 1 "$?" "$WORK/push-bad.out"
assert_tool_status "pre-push refusal names the violation" FAIL "$WORK/push-bad.out" ruff-check
git -C "$REMOTE" show-ref --verify --quiet refs/heads/feat/violations
assert_rc "rejected push leaves remote ref absent" 1 "$?" "$WORK/push-bad.out"

# Linked worktree gets the hook too, and blocks a planted fake secret via gitleaks.
WT="$WORK/wt-secret"
git -C "$REPO" worktree add -q -b feat/secret "$WT" main
# Construct fake GitHub token dynamically so this test file never holds a literal token.
printf 'token = "%s%s"\n' 'ghp_A1b2C3d4E5f6G7h8' 'I9j0K1l2M3n4O5p6Q7r8' >"$WT/leak.txt"
git -C "$WT" add leak.txt
git -C "$WT" commit -q -m "add secret"
git -C "$WT" push origin feat/secret >"$WORK/push-secret.out" 2>&1
assert_rc "pre-push in linked worktree refuses push with planted secret" 1 "$?" "$WORK/push-secret.out"
git -C "$REMOTE" show-ref --verify --quiet refs/heads/feat/secret
assert_rc "rejected secret leaves remote ref absent" 1 "$?" "$WORK/push-secret.out"
assert_grep "gitleaks failed on planted secret" "^gitleaks[[:space:]]+FAIL" "$WORK/push-secret.out"

# Clean push from linked worktree succeeds.
git -C "$WT" reset -q --hard main
printf 'safe = "ok"\n' >"$WT/safe.txt"
git -C "$WT" add safe.txt
git -C "$WT" commit -q -m "safe change"
git -C "$WT" push -q -u origin feat/secret >"$WORK/push-wt-clean.out" 2>&1
rc=$?
assert_rc "pre-push in linked worktree allows clean push" 0 "$rc" "$WORK/push-wt-clean.out"

# Advisory semgrep test: semgrep finding alone does NOT fail push.
git -C "$REPO" checkout -q -b feat/semgrep main
cat >"$REPO/advisory.py" <<'PY'
"""Advisory semgrep check."""

import tempfile


def helper() -> str:
    return tempfile.mktemp()
PY
git -C "$REPO" add advisory.py
git -C "$REPO" commit -q -m "advisory semgrep finding"
git -C "$REPO" push -q -u origin feat/semgrep >"$WORK/push-semgrep.out" 2>&1
rc=$?
assert_rc "semgrep finding is advisory and allows clean blocking push" 0 "$rc" "$WORK/push-semgrep.out"
assert_tool_status "advisory-only push" FAIL "$WORK/push-semgrep.out" semgrep

# Check outgoing refs through the installed hook and CLI.
new_repo() {
	git init -qb main "$1"
	git -C "$1" config user.name test
	git -C "$1" config user.email test@localhost
	git -C "$1" config core.hooksPath "$1/.git/hooks"
}
save_commit() {
	git -C "$1" add -A
	git -C "$1" commit -qm fixture
}
run_push() {
	local dir="$1" output="$2"
	shift 2
	(cd "$dir" && printf '%s\n' "$@" | "$PRE_PUSH" origin) >"$output" 2>&1
}
ZERO=0000000000000000000000000000000000000000
FIX="$WORK/repair"
EMPTY="$WORK/empty.git"
new_repo "$FIX"
git init --bare -qb main "$EMPTY"
git -C "$FIX" remote add origin "$EMPTY"
"$AZ_LINT" --repo "$WORK/missing-repo" --changed >"$WORK/missing-repo.out" 2>&1
assert_rc "missing repository returns an input error" 2 "$?" "$WORK/missing-repo.out"
assert_grep "missing repository explains the error" '^az-lint: not a git repository:' "$WORK/missing-repo.out"
printf 'import sys\n' >"$FIX/bad.py"
save_commit "$FIX"
FIRST=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/first.out" "refs/heads/main $FIRST refs/heads/main $ZERO"
assert_rc "2 first push lints the root tree" 1 "$?" "$WORK/first.out"
assert_tool_status "2 first push" FAIL "$WORK/first.out" ruff-check
printf 'token = "%s%s"\n' 'ghp_A1b2C3d4E5f6G7h8' 'I9j0K1l2M3n4O5p6Q7r8' >"$FIX/leak.txt"
rm "$FIX/bad.py"
save_commit "$FIX"
git -C "$FIX" rm -q leak.txt
save_commit "$FIX"
TIP=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/first-history.out" "refs/heads/main $TIP refs/heads/main $ZERO"
assert_rc "2 first push scans intermediate commits" 1 "$?" "$WORK/first-history.out"
assert_tool_status "2 first-push history" FAIL "$WORK/first-history.out" gitleaks

git -C "$FIX" checkout -q --orphan base
git -C "$FIX" commit -qm base --allow-empty
git -C "$FIX" push -qu origin HEAD:main
BASE=$(git -C "$FIX" rev-parse HEAD)

git -C "$FIX" checkout -qb merge-scan-side "$BASE"
git -C "$FIX" commit -qm side --allow-empty
git -C "$FIX" checkout -qb merge-scan "$BASE"
git -C "$FIX" commit -qm local --allow-empty
git -C "$FIX" merge -q --no-ff --no-commit merge-scan-side
git -C "$FIX" show "$TIP^:leak.txt" >"$FIX/leak.txt"
save_commit "$FIX"
MERGED=$(git -C "$FIX" rev-parse HEAD)
"$AZ_LINT" --repo "$FIX" --changed "$BASE" >"$WORK/merge-scan-changed.out" 2>&1
assert_rc "changed mode scans the merge diff" 1 "$?" "$WORK/merge-scan-changed.out"
assert_tool_status "changed mode merge diff" FAIL "$WORK/merge-scan-changed.out" gitleaks
run_push "$FIX" "$WORK/merge-scan-push.out" "refs/heads/merge-scan $MERGED refs/heads/merge-scan $ZERO"
assert_rc "pre-push scans the merge diff" 1 "$?" "$WORK/merge-scan-push.out"
assert_tool_status "pre-push merge diff" FAIL "$WORK/merge-scan-push.out" gitleaks

git -C "$FIX" checkout -qb non-object-manifest "$BASE"
printf 'null\n' >"$FIX/package.json"
printf 'export const value = 1;\n' >"$FIX/value.ts"
printf '[tools]\nbiome = false\n' >"$FIX/.az-lint.toml"
save_commit "$FIX"
"$AZ_LINT" --repo "$FIX" --changed "$BASE" >"$WORK/non-object-manifest.out" 2>&1
assert_rc "non-object manifest leaves independent checks runnable" 0 "$?" "$WORK/non-object-manifest.out"
assert_tool_status "non-object manifest" SKIP "$WORK/non-object-manifest.out" tsc
assert_tool_status "non-object manifest" PASS "$WORK/non-object-manifest.out" gitleaks

git -C "$FIX" checkout -qb one "$BASE"
printf 'value = 1\n' >"$FIX/one.py"
printf 'value = 1\n' >"$FIX/shared.py"
save_commit "$FIX"
ONE=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" checkout -qb two "$BASE"
printf 'other = 2\n' >"$FIX/two.py"
printf 'value = 2\n' >"$FIX/shared.py"
save_commit "$FIX"
TWO=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/multi-clean.out" "refs/heads/one $ONE refs/heads/one $ZERO" "refs/heads/two $TWO refs/heads/two $ZERO"
assert_rc "1 clean multi-ref push" 0 "$?" "$WORK/multi-clean.out"
assert_grep "1 each tip gets its own two files" '^ruff-check[[:space:]]+PASS[[:space:]]+2 file\(s\).*refs/heads/one' "$WORK/multi-clean.out"
assert_grep "1 second tip gets its own two files" '^ruff-check[[:space:]]+PASS[[:space:]]+2 file\(s\).*refs/heads/two' "$WORK/multi-clean.out"
# Force the branch that the old runner drops to contain the sole violation.
LOWER_BRANCH=one
HIGHER=$TWO
if [[ "$TWO" < "$ONE" ]]; then
	LOWER_BRANCH=two
	HIGHER=$ONE
fi
git -C "$FIX" checkout -q "$LOWER_BRANCH"
printf 'import sys\n' >"$FIX/shared.py"
printf 'import sys\n' >"$FIX/bad.py"
printf 'bad.py export-ignore\nshared.py export-ignore\n' >"$FIX/.gitattributes"
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/multi-bad.out" "refs/heads/good $HIGHER refs/heads/good $ZERO" "refs/heads/bad $BAD refs/heads/bad $ZERO"
assert_rc "1 multi-ref push lints snapshot with export-ignore" 1 "$?" "$WORK/multi-bad.out"
assert_grep "1 violation identified at its own tip" '^ruff-check[[:space:]]+FAIL.*refs/heads/bad' "$WORK/multi-bad.out"

git -C "$FIX" checkout -qb dirty-config "$BASE"
printf 'import sys\n' >"$FIX/shared.py"
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
printf 'lint.ignore = ["F401"]\n' >"$FIX/.ruff.toml"
run_push "$FIX" "$WORK/dirty-config.out" "refs/heads/dirty-config $BAD refs/heads/dirty-config $ZERO"
assert_rc "1 push uses committed Ruff config" 1 "$?" "$WORK/dirty-config.out"
assert_tool_status "1 dirty config leaves committed violation blocking" FAIL "$WORK/dirty-config.out" ruff-check
rm "$FIX/.ruff.toml"

git -C "$FIX" checkout -qb dash "$BASE"
printf 'value = 1\n' >"$FIX/-dash.py"
save_commit "$FIX"
"$AZ_LINT" --repo "$FIX" --changed "$BASE" >"$WORK/dash.out" 2>&1
assert_rc "7 filename starting with dash" 0 "$?" "$WORK/dash.out"
assert_tool_status "7 dash operand" PASS "$WORK/dash.out" ruff-check ruff-format

# A moving comparison branch must not make an untouched violation look changed.
git -C "$FIX" checkout -qb common "$BASE"
printf 'import sys\n' >"$FIX/bad.py"
save_commit "$FIX"
COMMON=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" checkout -qb updated-base "$COMMON"
git -C "$FIX" rm -q bad.py
save_commit "$FIX"
git -C "$FIX" checkout -qb only-ours "$COMMON"
printf 'clean = 1\n' >"$FIX/only_ours.py"
save_commit "$FIX"
"$AZ_LINT" --repo "$FIX" --changed updated-base >"$WORK/diverged.out" 2>&1
assert_rc "1 changed mode excludes changes made only on a diverged base" 0 "$?" "$WORK/diverged.out"
assert_grep "1 changed mode selects only the branch's file" '^ruff-check[[:space:]]+PASS[[:space:]]+1 file\(s\)' "$WORK/diverged.out"

# An existing branch push lints the branch's files after it merges main.
git -C "$FIX" checkout -qb merge-main "$BASE"
printf 'clean = 1\n' >"$FIX/branch.py"
save_commit "$FIX"
git -C "$FIX" push -qu origin merge-main
MERGE_OLD=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" checkout -qb main-update "$BASE"
printf 'import sys\n' >"$FIX/main_only.py"
save_commit "$FIX"
git -C "$FIX" push -q origin HEAD:main
git -C "$FIX" checkout -q merge-main
git -C "$FIX" merge -q --no-edit main-update
MERGE_TIP=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/merge-main.out" "refs/heads/merge-main $MERGE_TIP refs/heads/merge-main $MERGE_OLD"
assert_rc "BUG5-clean merged main violation does not block the branch" 0 "$?" "$WORK/merge-main.out"
assert_grep "BUG5-clean Ruff checks the one branch file" '^ruff-check[[:space:]]+PASS[[:space:]]+1 file\(s\)' "$WORK/merge-main.out"

printf 'import sys\n' >"$FIX/branch.py"
save_commit "$FIX"
MERGE_TIP=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/merge-main-bad.out" "refs/heads/merge-main $MERGE_TIP refs/heads/merge-main $MERGE_OLD"
assert_rc "BUG5-bad branch violation still blocks after merging main" 1 "$?" "$WORK/merge-main-bad.out"
assert_tool_status "BUG5-bad branch violation" FAIL "$WORK/merge-main-bad.out" ruff-check

# A remote HEAD with the same tree still needs shared history with the branch.
MAIN_HEAD=$(git -C "$EMPTY" rev-parse HEAD)
MERGE_TREE=$(git -C "$FIX" rev-parse "$MERGE_TIP^{tree}")
UNRELATED_HEAD=$(git -C "$FIX" commit-tree "$MERGE_TREE" -m 'unrelated default branch')
git -C "$EMPTY" fetch -q "$FIX" "+$UNRELATED_HEAD:refs/heads/main"
run_push "$FIX" "$WORK/unrelated-head.out" "refs/heads/merge-main $MERGE_TIP refs/heads/merge-main $MERGE_OLD"
assert_rc "unrelated remote HEAD blocks the push" 2 "$?" "$WORK/unrelated-head.out"
assert_grep "unrelated HEAD explains how to recover" '^az-lint: Cannot establish pre-push base: no merge base with remote HEAD; fetch the remote default branch' "$WORK/unrelated-head.out"

UNFETCHED_HEAD=$(git -C "$EMPTY" -c user.name=test -c user.email=test@localhost \
	commit-tree "$MERGE_TREE" -p "$MAIN_HEAD" -m 'unfetched default branch')
git -C "$EMPTY" update-ref refs/heads/main "$UNFETCHED_HEAD"
run_push "$FIX" "$WORK/unfetched-head.out" "refs/heads/merge-main $MERGE_TIP refs/heads/merge-main $MERGE_OLD"
assert_rc "unfetched remote HEAD blocks the push" 2 "$?" "$WORK/unfetched-head.out"
assert_grep "unfetched HEAD explains how to recover" '^az-lint: Cannot establish pre-push base: no merge base with remote HEAD; fetch the remote default branch' "$WORK/unfetched-head.out"
git -C "$EMPTY" update-ref refs/heads/main "$MAIN_HEAD"

git -C "$FIX" checkout -qb protected "$BASE"
git -C "$FIX" show "$TIP^:leak.txt" >"$FIX/leak.txt"
printf '[tools]\ngitleaks = false\n' >"$FIX/.az-lint.toml"
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/disabled.out" "refs/heads/protected $BAD refs/heads/protected $ZERO"
assert_rc "3 disabled config cannot skip push scan" 1 "$?" "$WORK/disabled.out"
assert_tool_status "3 mandatory scan" FAIL "$WORK/disabled.out" gitleaks
printf '[tools.gitleaks]\noverride_args = ["version"]\n' >"$FIX/.az-lint.toml"
printf '#!/usr/bin/env bash\nif [ "$#" -gt 0 ];then\necho "%s"\nfi\n' "$(sed -n 's/token = "\(.*\)"/\1/p' "$FIX/leak.txt")" >"$FIX/bad.sh"
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
(
	umask 000
	run_push "$FIX" "$WORK/redact.out" "refs/heads/protected $BAD refs/heads/protected $ZERO"
)
assert_rc "4 push with a detected secret and bad formatting" 1 "$?" "$WORK/redact.out"
assert_tool_status "3 replacement arguments cannot replace scan" FAIL "$WORK/redact.out" gitleaks
git -C "$FIX" rm -q .az-lint.toml
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
(
	umask 000
	run_push "$FIX" "$WORK/redact.out" "refs/heads/protected $BAD refs/heads/protected $ZERO"
)
assert_rc "4 rejection still reports failed tools" 1 "$?" "$WORK/redact.out"
assert_tool_status "4 detected secret in range" FAIL "$WORK/redact.out" gitleaks
assert_tool_status "4 formatter also fails" FAIL "$WORK/redact.out" shfmt
logf=$(sed -n 's/^log: //p' "$WORK/redact.out")
if [[ -f "$logf" ]]; then
	needle=$(sed -n 's/token = "\(.*\)"/\1/p' "$FIX/leak.txt")
	grep -Fq -- "$needle" "$logf" "$WORK/redact.out"
	assert_rc "4 scanner and formatter output contain no secret" 1 "$?" /dev/null
	assert_rc "4 log permissions are owner-only" 600 "$(stat -c '%a' "$logf")" /dev/null
else
	fail "4 pushed secret log exists" "no lint log found"
fi

git -C "$FIX" checkout -qb allowlist "$BASE"
git -C "$FIX" show "$TIP^:leak.txt" >"$FIX/allowlisted.txt"
save_commit "$FIX"
BAD=$(git -C "$FIX" rev-parse HEAD)
printf '%s:allowlisted.txt:github-pat:1\n' "$BAD" >"$FIX/.gitleaksignore"
run_push "$FIX" "$WORK/dirty-allowlist.out" "refs/heads/allowlist $BAD refs/heads/allowlist $ZERO"
assert_rc "3 a dirty allowlist does not suppress a pushed secret" 1 "$?" "$WORK/dirty-allowlist.out"
assert_tool_status "3 dirty allowlist" FAIL "$WORK/dirty-allowlist.out" gitleaks
save_commit "$FIX"
GOOD=$(git -C "$FIX" rev-parse HEAD)
run_push "$FIX" "$WORK/allowlist.out" "refs/heads/allowlist $GOOD refs/heads/allowlist $ZERO"
assert_rc "3 a committed fingerprint exclusion is honored" 0 "$?" "$WORK/allowlist.out"
assert_grep "3 runner reports committed allowlist" '^gitleaks[[:space:]]+PASS.*allowlist: \.gitleaksignore' "$WORK/allowlist.out"

git -C "$FIX" checkout -qb scope "$BASE"
mkdir -p "$FIX/src" "$FIX/node_modules/.bin" "$FIX/.github/workflows"
printf '/node_modules/\n' >>"$FIX/.git/info/exclude"
install_tsc "$FIX/node_modules/.bin"
git -C "$REPO" show feat/violations:rust_ws/Cargo.toml >"$FIX/Cargo.toml"
git -C "$REPO" show feat/violations:rust_ws/Cargo.lock >"$FIX/Cargo.lock"
printf 'mod unchanged;\n' >"$FIX/src/lib.rs"
printf 'pub fn other(){let unused=1;}\n' >"$FIX/src/unchanged.rs"
printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >"$FIX/package.json"
printf '{}\n' >"$FIX/tsconfig.json"
printf 'export const bad: number = "wrong type";\n' >"$FIX/bad.ts"
save_commit "$FIX"
SCOPE_BASE=$(git -C "$FIX" rev-parse HEAD)
printf 'mod unchanged;\n\npub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n' >"$FIX/src/lib.rs"
printf 'export const clean = 1;\n' >"$FIX/clean.ts"
"$AZ_LINT" --repo "$FIX" --changed "$SCOPE_BASE" >"$WORK/scope.out" 2>&1
assert_rc "6 unchanged Rust and TypeScript problems are advisory" 0 "$?" "$WORK/scope.out"
for tool in cargo-fmt cargo-clippy tsc; do
	assert_grep "6 $tool reports advisory diagnostics" "^${tool}[[:space:]]+PASS.*advisory" "$WORK/scope.out"
done
# The ordinary compiler still runs if the script uses a different command.
printf '{"scripts":{"typecheck":"printf script-ran > script-marker"}}\n' >"$FIX/package.json"
"$AZ_LINT" --repo "$FIX" --changed "$SCOPE_BASE" >"$WORK/script.out" 2>&1
assert_rc "8 nonstandard script text leaves compiler result intact" 0 "$?" "$WORK/script.out"
if [[ -e "$FIX/script-marker" ]]; then
	fail "8 package script never runs" "script created a marker" "$WORK/script.out"
else
	ok "8 package script never runs"
fi
assert_grep "8 local compiler still reports project diagnostics" '^tsc[[:space:]]+PASS.*advisory' "$WORK/script.out"
rm -f "$FIX/script-marker"

save_commit "$FIX"
ACTION_BASE=$(git -C "$FIX" rev-parse HEAD)
git -C "$REPO" show feat/clean:.github/workflows/clean.yml >"$FIX/.github/workflows/clean.yml"
cat >>"$FIX/.github/workflows/clean.yml" <<'YML'
  custom:
    runs-on: [self-hosted, additional-runner]
    steps:
      - run: echo custom
YML
printf 'self-hosted-runner:\n  labels: [additional-runner]\n' >"$FIX/.github/actionlint.yml"
save_commit "$FIX"
"$AZ_LINT" --repo "$FIX" --changed "$ACTION_BASE" >"$WORK/actionlint.out" 2>&1
assert_rc "9 Actionlint extends valid configured labels" 0 "$?" "$WORK/actionlint.out"
assert_tool_status "9 Actionlint config with parser" PASS "$WORK/actionlint.out" actionlint
python3 -ES "$AZ_LINT" --repo "$FIX" --changed "$ACTION_BASE" >"$WORK/actionlint-no-yaml.out" 2>&1
assert_rc "9 missing YAML parser is an explicit prerequisite" 3 "$?" "$WORK/actionlint-no-yaml.out"
assert_grep "9 Actionlint names the missing parser" '^actionlint[[:space:]]+MISSING.*PyYAML' "$WORK/actionlint-no-yaml.out"

UNTRUSTED="$WORK/untrusted"
new_repo "$UNTRUSTED"
git -C "$UNTRUSTED" commit -qm base --allow-empty
mkdir -p "$UNTRUSTED/node_modules/.bin" "$UNTRUSTED/src" "$WORK/tool-links"
printf '#!/bin/sh\nprintf ran > "%s"\n' "$WORK/checkout-tool-ran" \
	>"$UNTRUSTED/node_modules/.bin/biome"
cp "$UNTRUSTED/node_modules/.bin/biome" "$UNTRUSTED/node_modules/.bin/tsc"
cp "$UNTRUSTED/node_modules/.bin/biome" "$UNTRUSTED/node_modules/.bin/ruff"
chmod +x "$UNTRUSTED/node_modules/.bin/"*
ln -s "$UNTRUSTED/node_modules/.bin/ruff" "$WORK/tool-links/ruff"
printf '/node_modules/\n' >>"$UNTRUSTED/.git/info/exclude"
printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >"$UNTRUSTED/package.json"
printf '[tools]\nruff = false\n' >"$UNTRUSTED/.az-lint.toml"
printf 'x = 1\n' >"$UNTRUSTED/clean.py"
printf '*.py filter=marker\n' >"$UNTRUSTED/.gitattributes"
printf '#!/bin/sh\nprintf ran > "%s"\ncat\n' "$WORK/git-filter-ran" \
	>"$UNTRUSTED/node_modules/.bin/clean-filter"
chmod +x "$UNTRUSTED/node_modules/.bin/clean-filter"
git -C "$UNTRUSTED" config filter.marker.clean ./node_modules/.bin/clean-filter
git -C "$UNTRUSTED" config filter.marker.required true
git -C "$UNTRUSTED" add .gitattributes clean.py
git -C "$UNTRUSTED" commit -qm "file with a Git clean filter"
if [[ -e "$WORK/git-filter-ran" ]]; then
	ok "10 Git can execute the configured clean filter"
	rm "$WORK/git-filter-ran"
else
	fail "10 Git clean filter fixture" "expected the filter to create a marker"
fi
printf 'x = 2\n' >"$UNTRUSTED/clean.py"
printf 'export const answer = 42;\n' >"$UNTRUSTED/clean.js"
printf 'fn main() {}\n' >"$UNTRUSTED/src/main.rs"
printf '[package]\nname = "fixture"\nversion = "0.1.0"\n' >"$UNTRUSTED/Cargo.toml"
printf '#!/bin/sh\nexit 0\n' >"$UNTRUSTED/scan.sh"
git -C "$REPO" show feat/violations:bad.yaml >"$UNTRUSTED/bad.yaml"
printf 'extends: default\nrules:\n  key-duplicates: disable\n' >"$UNTRUSTED/.yamllint"
mkdir "$WORK/external"
printf 'import unused\n' >"$WORK/external/outside.py"
ln -s "$WORK/external" "$UNTRUSTED/linked"
PATH="$UNTRUSTED/node_modules/.bin:$WORK/tool-links:$PATH" \
	"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD >"$WORK/untrusted.out" 2>&1
assert_rc "10 untrusted ignores checkout yamllint config and rejects duplicate keys" 1 "$?" "$WORK/untrusted.out"
assert_tool_status "10 untrusted fixed checks" PASS "$WORK/untrusted.out" ruff-check ruff-format gitleaks
assert_tool_status "10 untrusted YAML" FAIL "$WORK/untrusted.out" yamllint
assert_tool_status "10 untrusted project-dependent checks" SKIP "$WORK/untrusted.out" cargo-fmt cargo-clippy tsc semgrep
assert_grep "10 untrusted clippy skip explains why" '^cargo-clippy[[:space:]]+SKIP.*build scripts' "$WORK/untrusted.out"
if [[ -e "$WORK/checkout-tool-ran" || -e "$WORK/git-filter-ran" ]]; then
	fail "10 untrusted scripts stay inert" "a checkout binary or Git filter ran" "$WORK/untrusted.out"
else
	ok "10 untrusted scripts stay inert"
fi

rm "$UNTRUSTED/bad.yaml"
if [[ " ${REAL_TOOLS[*]} " == *" shellcheck "* ]]; then
	SHELLCHECK_OPTS=--shell=invalid "$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD \
		>"$WORK/untrusted-shellcheck-env.out" 2>&1
	assert_tool_status "10 untrusted ignores caller ShellCheck options" PASS "$WORK/untrusted-shellcheck-env.out" shellcheck
fi
git -C "$UNTRUSTED" config format.pretty invalid-fixture-format
GIT_TRACE="$WORK/untrusted-git.trace" "$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD^ \
	>"$WORK/untrusted-git-settings.out" 2>&1
assert_tool_status "10 untrusted Git presentation settings" PASS "$WORK/untrusted-git-settings.out" gitleaks
if [[ -e "$WORK/untrusted-git.trace" ]]; then
	fail "10 untrusted Git writes only runner logs" "Git tracing wrote a separate file"
else
	ok "10 untrusted ignores ambient Git tracing"
fi
git -C "$UNTRUSTED" config --unset format.pretty
printf '[tools.ruff-check]\noverride_args = ["check", "--fix"]\n' >"$WORK/trusted.toml"
AZ_LINT_UNTRUSTED=1 "$AZ_LINT" --repo "$UNTRUSTED" --changed HEAD \
	--config "$WORK/trusted.toml" >"$WORK/untrusted-env.out" 2>&1
assert_rc "10 environment switch accepts external config" 0 "$?" "$WORK/untrusted-env.out"
assert_grep "10 untrusted refuses argument overrides" '^ruff-check[[:space:]]+SKIP.*custom arguments' "$WORK/untrusted-env.out"
ln -s "$UNTRUSTED/.az-lint.toml" "$WORK/linked.toml"
"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD \
	--config "$WORK/linked.toml" >"$WORK/untrusted-config.out" 2>&1
assert_rc "10 untrusted rejects config symlink into checkout" 2 "$?" "$WORK/untrusted-config.out"
assert_grep "10 untrusted config explains rejection" 'config.*outside.*checkout' "$WORK/untrusted-config.out"

printf '#!/bin/sh\nexit 0\n' >"$UNTRUSTED/"$'-script with spaces\nand newline.sh'
save_commit "$UNTRUSTED"
UNTRUSTED_TIP=$(git -C "$UNTRUSTED" rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$UNTRUSTED_TIP" "$ZERO" |
	"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --pre-push >"$WORK/untrusted-names.out" 2>&1
assert_rc "10 untrusted pre-push accepts spaces, newlines and leading dashes" 0 "$?" "$WORK/untrusted-names.out"
assert_grep "10 untrusted pre-push checks both shell files" '^shellcheck[[:space:]]+PASS[[:space:]]+2 file\(s\)' "$WORK/untrusted-names.out"

git -C "$FIX" show "$TIP^:leak.txt" >"$UNTRUSTED/leak.txt"
save_commit "$UNTRUSTED"
UNTRUSTED_TIP=$(git -C "$UNTRUSTED" rev-parse HEAD)
printf '%s:leak.txt:github-pat:1\n' "$UNTRUSTED_TIP" >"$UNTRUSTED/.gitleaksignore"
"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD^ >"$WORK/untrusted-leak.out" 2>&1
assert_rc "10 untrusted detects secret despite checkout allowlist" 1 "$?" "$WORK/untrusted-leak.out"
assert_tool_status "10 untrusted secrets remain blocking" FAIL "$WORK/untrusted-leak.out" gitleaks
printf 'refs/heads/main %s refs/heads/main %s\n' "$UNTRUSTED_TIP" "$ZERO" |
	"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --pre-push --remote-url "$WORK/absent" \
		>"$WORK/untrusted-push.out" 2>&1
assert_rc "10 untrusted pre-push scans without remote access" 1 "$?" "$WORK/untrusted-push.out"
assert_tool_status "10 untrusted pre-push still detects secret" FAIL "$WORK/untrusted-push.out" gitleaks

mkdir "$WORK/fallback-tmp"
touch "$WORK/state-collision"
AZ_LINT_LOG_DIR="$WORK/state-collision/az-lint" TMPDIR="$WORK/fallback-tmp" \
	"$AZ_LINT" --repo "$FIX" --changed HEAD >"$WORK/log-fallback.out" 2>&1
assert_rc "11 log directory failure falls back successfully" 0 "$?" "$WORK/log-fallback.out"
fallback_log=$(sed -n 's/^log: //p' "$WORK/log-fallback.out")
assert_rc "11 fallback directory is private" 700 "$(stat -c '%a' "${fallback_log%/*}")" "$WORK/log-fallback.out"
assert_rc "11 fallback log is private" 600 "$(stat -c '%a' "$fallback_log")" "$WORK/log-fallback.out"

AZ_LINT_LOG_DIR="$UNTRUSTED/local-logs" TMPDIR="$WORK/fallback-tmp" \
	"$AZ_LINT" --untrusted --repo "$UNTRUSTED" --changed HEAD >"$WORK/untrusted-log.out" 2>&1
assert_rc "11 untrusted log falls back outside the checkout" 0 "$?" "$WORK/untrusted-log.out"
untrusted_log=$(sed -n 's/^log: //p' "$WORK/untrusted-log.out")
if [[ "$untrusted_log" == "$WORK/fallback-tmp/az-lint-"* && ! -e "$UNTRUSTED/local-logs" ]]; then
	ok "11 untrusted log destination leaves checkout untouched"
else
	fail "11 untrusted log destination" "expected a private temporary log outside the checkout" "$WORK/untrusted-log.out"
fi

WHITESPACE_REPO="$WORK/"$'checkout with trailing whitespace \n'
new_repo "$WHITESPACE_REPO"
git -C "$WHITESPACE_REPO" commit -qm base --allow-empty
printf '#!/bin/sh\nexit 0\n' >"$WHITESPACE_REPO/scan.sh"
"$AZ_LINT" --untrusted --repo "$WHITESPACE_REPO" --changed HEAD >"$WORK/untrusted-root-name.out" 2>&1
assert_rc "11 untrusted checkout name can end in whitespace" 0 "$?" "$WORK/untrusted-root-name.out"
assert_tool_status "11 untrusted checkout with whitespace" PASS "$WORK/untrusted-root-name.out" shellcheck gitleaks
whitespace_log=$(sed -n 's/^log: //p' "$WORK/untrusted-root-name.out")
if [[ -f "$whitespace_log" ]]; then
	ok "11 untrusted checkout with whitespace prints a usable log path"
else
	fail "11 untrusted checkout log path" "expected a single usable path" "$WORK/untrusted-root-name.out"
fi

printf '[tools.semgrep]\noverride_args = ["scan", "--config", ".semgrep.yml", "--error"]\n' \
	>"$WORK/semgrep-override.toml"
"$AZ_LINT" --repo "$REPO" --changed main --config "$WORK/semgrep-override.toml" \
	>"$WORK/semgrep-offline.out" 2>&1
assert_grep "12 Semgrep scan with overrides reports findings" \
	'^semgrep[[:space:]]+FAIL.*findings printed' "$WORK/semgrep-offline.out"
semgrep_log=$(sed -n 's/^log: //p' "$WORK/semgrep-offline.out")
assert_grep "12 Semgrep overrides keep version checks and metrics off" \
	'^\$ .*semgrep .*--metrics off --disable-version-check' "$semgrep_log"

HOOK_REPO="$WORK/hook-source"
HOOK_WT="$WORK/hook-worktree"
new_repo "$HOOK_REPO"
git -C "$HOOK_REPO" commit -qm base --allow-empty
git -C "$HOOK_REPO" config --local core.hooksPath .hooks
git -C "$HOOK_REPO" worktree add -qb linked "$HOOK_WT"
"$INSTALL_HOOK" "$HOOK_REPO" >"$WORK/install-relative.out" 2>&1
assert_rc "5 install relative hooks path" 0 "$?" "$WORK/install-relative.out"
git -C "$HOOK_WT" hook run pre-push </dev/null >"$WORK/run-relative.out" 2>&1
assert_rc "5 Git runs installed hook in linked checkout" 0 "$?" "$WORK/run-relative.out"
assert_tool_status "5 linked worktree runs az-lint" SKIP "$WORK/run-relative.out" gitleaks
mkdir -p "$WORK/inherited"
printf '#!/bin/sh\nprintf "%s\\n" inherited-hook\n' '%s' >"$WORK/inherited/post-commit"
chmod +x "$WORK/inherited/post-commit"
git -C "$HOOK_REPO" config --local --unset core.hooksPath
git config --global core.hooksPath "$WORK/inherited"
"$INSTALL_HOOK" "$HOOK_REPO" >"$WORK/install-inherited.out" 2>&1
assert_rc "5 install with inherited hooks path" 0 "$?" "$WORK/install-inherited.out"
git -C "$HOOK_WT" hook run pre-push </dev/null >"$WORK/run-inherited.out" 2>&1
assert_rc "5 Git runs installed hook with inherited config" 0 "$?" "$WORK/run-inherited.out"
git -C "$HOOK_WT" hook run post-commit >"$WORK/other-hook.out" 2>&1
assert_rc "5 inherited post-commit hook remains runnable" 0 "$?" "$WORK/other-hook.out"
assert_grep "5 inherited hook preserved" '^inherited-hook$' "$WORK/other-hook.out"
mkdir -p "$WORK/conflicting"
printf '#!/bin/sh\n# az-lint\nexit 0\n' >"$WORK/conflicting/pre-push"
chmod +x "$WORK/conflicting/pre-push"
git -C "$HOOK_REPO" config --local core.hooksPath "$WORK/conflicting"
"$INSTALL_HOOK" "$HOOK_REPO" >"$WORK/false-install.out" 2>&1
assert_rc "5 a text mention does not install az-lint" 1 "$?" "$WORK/false-install.out"
assert_grep "5 existing hook reports conflict" 'conflicting hook' "$WORK/false-install.out"
unset GIT_CONFIG_GLOBAL

printf '\nSummary: passed=%d failed=%d\n' "$pass_count" "$failures"
if [[ "$failures" -gt 0 ]]; then
	exit 1
fi
exit 0
