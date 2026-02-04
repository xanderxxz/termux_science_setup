# Termux Science Setup

Install a reproducible scientific Python stack on Termux with one script and profile flags.

## Highlights

- Strict-mode installer (`set -euo pipefail`) with line-level error reporting.
- Re-runnable package installs (already-installed `pkg` packages are skipped).
- Graceful fallback when a Termux package is unavailable (script skips it and continues with pip-managed deps).
- Reproducible Python dependency resolution via `requirements.txt` + `constraints.txt`.
- Optional virtual environment support.
- Optional OpenAI Codex CLI install (`--install-codex`).
- Generated install reports:
  - `installed-freeze.txt`
  - `installed-env.txt`

## Requirements

- Android device with Termux (F-Droid build recommended)
- At least 6 GB free storage
- 4 GB RAM recommended

## Quick Start

```bash
pkg install -y git
git clone -b feature/codex-cli-install https://github.com/xanderxxz/termux_science_setup.git
cd termux_science_setup
chmod +x termux_science_setup.sh
./termux_science_setup.sh --full
```

Run validation:

```bash
python scientific-libraries-test.py
```

If you installed the lite profile, run:

```bash
python scientific-libraries-test.py --lite
```

## Installer Flags

```bash
./termux_science_setup.sh [options]
```

- `--lite`: minimal data-science profile (`numpy`, `pandas`, `matplotlib`, optional JupyterLab).
- `--full`: full profile (default), adds `scipy`, `scikit-learn`, `statsmodels`, `opencv`, etc.
- `--no-jupyter`: skip JupyterLab.
- `--install-codex`: install OpenAI Codex CLI globally with npm (`@openai/codex`).
- `--venv <path>`: create/use a virtual environment and install pip packages there.
- `--with-upgrade`: run `pkg upgrade -y` after `pkg update -y`.
- `--keep-cache`: keep pip cache under `./_build/pip-cache` (default disables pip cache).
- `--dry-run`: print commands without executing.
- `--clean`: remove installer-generated artifacts (`./_build`, `installed-freeze.txt`, `installed-env.txt`).

## Example Commands

Full install:

```bash
./termux_science_setup.sh --full
```

Lite install:

```bash
./termux_science_setup.sh --lite
```

Full install in virtual environment:

```bash
./termux_science_setup.sh --full --venv .venv
. .venv/bin/activate
python scientific-libraries-test.py
```

Dry-run preview:

```bash
./termux_science_setup.sh --full --dry-run
```

Install full profile + Codex CLI:

```bash
./termux_science_setup.sh --full --install-codex
codex --login
codex
```

Clean generated artifacts:

```bash
./termux_science_setup.sh --clean
```

## Notes on Reproducibility

- Python package versions are pinned through `constraints.txt`.
- Termux `pkg` repositories are rolling; exact native package versions can still change over time.

## OpenMP Sysconfig Patch Guard

The installer checks for `-fno-openmp-implicit-rpath` in Python sysconfig and patches only when needed.

- It requires exactly one matching `*sysconfigdata*.py` file.
- It creates a timestamped backup in `./_build/backups/`.
- On script failure, the backup is auto-restored by trap.
- A restore command is printed after patching.

## Troubleshooting

1. Storage pressure during pip builds
   - Keep default no-cache behavior, or run `--clean` before retrying.
2. Unexpected package resolver conflicts
   - Check `installed-freeze.txt` and `installed-env.txt`.
3. OpenMP patch concerns
   - Use the printed restore command to revert sysconfig.
4. `E: Unable to locate package ...`
   - The installer now skips unavailable `pkg` names automatically; rerun the script after `pkg update -y`.

## Quality Checks

Run ShellCheck locally:

```bash
pkg install -y shellcheck
shellcheck termux_science_setup.sh
```

The repo includes a GitHub Actions workflow that runs:

- ShellCheck on `termux_science_setup.sh`
- Python smoke validation (`scientific-libraries-test.py`) in a standard Ubuntu venv
  (this catches regressions but does not emulate Termux internals).

## License

MIT License (`LICENSE`)
