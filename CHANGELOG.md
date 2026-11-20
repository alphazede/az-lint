# Changelog

## [0.1.3]

- Skip TypeScript checks for packages without a reachable `tsconfig.json`. A package can use a config from a parent directory inside the checkout.
- Keep package-local Biome checks available when TypeScript has no project config.

## [0.1.2]

- Preserve executable file modes in untrusted linting so Ruff accepts executable Python scripts with shebangs.

## [0.1.1]

- Add `--untrusted` for offline linting of untrusted checkouts.
- Use a private temporary log directory when the configured directory is unavailable.
- Disable Semgrep metrics and version checks, including with custom arguments.

## [0.1.0]

- Package the [changed-file lint runner and pre-push hook](README.md) for standalone use.
