# az-lint

az-lint selects language linters by the extensions of changed files. Run it
with `--changed <base>` in CI or install the pre-push hook to check outgoing
commits and file changes before a push.

## Tools

Install Git, Bash, Python 3.10 or newer, Gitleaks, and the linters for your files.
The runner looks for linters on `PATH`. Biome can also use a local installation.
When `package.json` defines a `typecheck` script, the runner invokes the local
`node_modules/.bin/tsc --noEmit` directly. Clippy uses `--offline --locked` by
default, so keep `Cargo.lock` and install project dependencies before linting.
Run az-lint with the same trust and isolation you use for the project's build.
Project tools such as Clippy can execute build scripts.

| Files | Linters and tested versions |
| --- | --- |
| Rust | Rustfmt 1.8.0, Clippy 0.1.94, Cargo 1.94.1 |
| Python | Ruff 0.17.3 |
| Shell | ShellCheck 0.11.0, shfmt 3.14.1 |
| GitHub Actions and YAML | Actionlint 1.7.12, yamllint 1.38.0 |
| JavaScript, TypeScript and React | Biome 2.6.5, TypeScript 7.0.2 |
| SQL | SQLFluff 4.5.0 |
| Verilog and SystemVerilog | Verible lint and format 0.0-4298-g085eef05, Verilator 5.046 |
| C and C++ | clang-format 23.1.5, Cppcheck 2.19.0 |
| Secret scanning | Gitleaks 8.30.1 |
| Static analysis | Semgrep 1.183.0 |

On 2026-11-19, the package self-tests used the tool versions above with Git
2.53.0 and Python 3.14.4 on Linux. Install PyYAML if az-lint needs to extend an
existing Actionlint configuration. The self-tests used PyYAML 6.0.3.

## Install the pre-push hook

Set `AZ_LINT_TAG` to a published tag and clone az-lint alongside your project.

```bash
git clone --branch "${AZ_LINT_TAG:?Set AZ_LINT_TAG to a release tag}" --depth 1 \
  https://github.com/alphazede/az-lint.git
./az-lint/install-hook ./my-project
```

The installer verifies the hook in the target repository and its linked
worktrees. Keep the az-lint checkout at that path while the hook is in use. If
the installer reports a conflict, integrate the runner's `--pre-push` command
into the existing hook. Forward the remote name and URL as `--remote "$1"`
and `--remote-url "$2"`, and pass Git's pre-push refs on standard input.

## Run in GitHub Actions

For a `pull_request` job, check out the project with full history and put
az-lint in a sibling directory. Replace the example `ref` with the full commit
SHA behind the release tag. Install the applicable linters before the last
step.

```yaml
- name: Check out project
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
  with:
    path: project
    fetch-depth: 0
    persist-credentials: false
- name: Check out az-lint
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
  with:
    repository: alphazede/az-lint
    ref: '0000000000000000000000000000000000000000'
    path: az-lint-package
    persist-credentials: false
- name: Lint changed files
  working-directory: project
  env:
    BASE_SHA: ${{ github.event.pull_request.base.sha }}
  run: ../az-lint-package/az-lint --changed "$BASE_SHA"
```

## Configure a repository

Put `.az-lint.toml` at the repository root. Use top-level `exclude` for file
patterns shared by language linters. Use `[tools.<id>]` to set `enabled`,
`args`, `override_args`, or tool-specific `exclude`. The runner prints the
tool IDs in its summary.

```toml
exclude = ["generated/**"]

[tools.ruff-check]
args = ["--ignore", "E501"]

[tools.semgrep]
args = ["--config", "rules/semgrep.yml"]
```

Gitleaks scans outgoing history, including merge commits. In `--changed`
mode, it scans the commit range and uncommitted changes in the working tree.
It scans the full history on a first push to an empty remote. Lint exclusions,
`enabled`, and argument overrides cannot disable or change the scan. Record
approved fingerprint exceptions in `.gitleaksignore` at the repository root.
A finding in a merge diff has its own fingerprint. The runner suppresses
Gitleaks output and reports the status.

Semgrep checks changed files when it finds `.semgrep.yml` or `.semgrep` at the
repository root, or when you supply a rules configuration. Its findings and
errors are advisory.

## Read the result

Exit `0` means all applicable blocking checks passed. Exit `1` means a
blocking check failed. Exit `2` means the runner could not load its input or
configuration. Exit `3` means a required tool is missing and no blocking tool
reported a failure. The summary prints the path to the detailed log.

If a new branch push reports that it cannot establish a comparison base,
fetch the remote default branch and check that the histories share a commit.

## Run self-tests

Run `bash tests/test-az-lint.sh` to use installed linters and substitute stubs
for any missing linters. Set `AZ_LINT_STUBS_ONLY=1` to use stubs for every
linter. Both modes require PyYAML for the Actionlint configuration test.

## License

Choose either the [Apache License 2.0](LICENSE-APACHE) or the [MIT license](LICENSE-MIT).
