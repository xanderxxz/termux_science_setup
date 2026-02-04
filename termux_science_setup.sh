#!/usr/bin/env bash
# Install a scientific Python stack in Termux with reproducible options.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/_build"
BACKUP_DIR="${BUILD_DIR}/backups"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints.txt"
FREEZE_OUTPUT="${SCRIPT_DIR}/installed-freeze.txt"
ENV_OUTPUT="${SCRIPT_DIR}/installed-env.txt"
STATSMODELS_VERSION="0.14.6"

PROFILE="full"
INSTALL_JUPYTER=1
WITH_UPGRADE=0
KEEP_CACHE=0
DRY_RUN=0
CLEAN_ONLY=0
VENV_PATH=""
PYTHON_BIN="python"
SELECTED_REQUIREMENTS=""
PATCHED_FILE=""
PATCH_BACKUP=""

BASE_PKGS=(
  git
  clang
  python
  libzmq
  rust
  binutils
  cmake
  wget
  which
  patchelf
)

BUILD_PKGS=(
  build-essential
  ninja
  flang
  libopenblas
  libandroid-execinfo
  binutils-is-llvm
)

LITE_PKGS=(
  python-numpy
  matplotlib
)

FULL_EXTRA_PKGS=(
  python-scipy
  python-pyarrow
)

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./termux_science_setup.sh [OPTIONS]

Profiles:
  --lite                Install minimal stack (numpy, pandas, matplotlib, optional jupyter)
  --full                Install full stack (default)

Optional behavior:
  --no-jupyter          Skip JupyterLab installation
  --venv <path>         Install Python packages inside a virtual environment
  --with-upgrade        Run pkg upgrade -y after pkg update -y
  --keep-cache          Keep pip cache in ./_build/pip-cache (default uses --no-cache-dir)
  --dry-run             Print commands without executing them
  --clean               Remove script-generated artifacts (./_build and install reports)
  -h, --help            Show this message
EOF
}

on_error() {
  local exit_code="$?"
  local line_number="${1:-unknown}"
  local command_text="${2:-unknown}"

  warn "Command failed at line ${line_number}: ${command_text}"

  if [[ -n "${PATCH_BACKUP}" && -n "${PATCHED_FILE}" && -f "${PATCH_BACKUP}" ]]; then
    warn "Restoring patched sysconfig file from backup: ${PATCH_BACKUP}"
    cp -- "${PATCH_BACKUP}" "${PATCHED_FILE}" || true
  fi

  exit "${exit_code}"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

run_cmd() {
  if (( DRY_RUN )); then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_commands() {
  local missing=()
  local command_name

  for command_name in "$@"; do
    if ! command_exists "${command_name}"; then
      missing+=("${command_name}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

is_pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

is_pkg_available() {
  apt-cache show -- "$1" >/dev/null 2>&1
}

install_missing_pkgs() {
  local packages=("$@")
  local missing=()
  local unavailable=()
  local package_name

  for package_name in "${packages[@]}"; do
    if is_pkg_installed "${package_name}"; then
      continue
    fi

    if is_pkg_available "${package_name}"; then
      missing+=("${package_name}")
    else
      unavailable+=("${package_name}")
    fi
  done

  if (( ${#unavailable[@]} > 0 )); then
    warn "Skipping unavailable pkg package(s): ${unavailable[*]}"
  fi

  if (( ${#missing[@]} == 0 )); then
    log "No installable pkg entries needed from set: ${packages[*]}"
    return
  fi

  run_cmd pkg install -y "${missing[@]}"
}

clean_generated_artifacts() {
  local paths=(
    "${BUILD_DIR}"
    "${FREEZE_OUTPUT}"
    "${ENV_OUTPUT}"
  )
  local target

  for target in "${paths[@]}"; do
    if [[ -e "${target}" ]]; then
      run_cmd rm -rf -- "${target}"
      log "Removed ${target}"
    fi
  done
}

prepare_python_context() {
  if [[ -z "${VENV_PATH}" ]]; then
    PYTHON_BIN="python"
    return
  fi

  if [[ ! -x "${VENV_PATH}/bin/python" ]]; then
    log "Creating virtual environment at ${VENV_PATH}"
    run_cmd python -m venv "${VENV_PATH}"
  fi

  PYTHON_BIN="${VENV_PATH}/bin/python"

  if [[ ! -x "${PYTHON_BIN}" ]]; then
    die "Unable to find Python executable in virtual environment: ${PYTHON_BIN}"
  fi
}

build_selected_requirements() {
  SELECTED_REQUIREMENTS="${BUILD_DIR}/requirements-selected.txt"
  run_cmd mkdir -p "${BUILD_DIR}"

  if (( DRY_RUN )); then
    log "Would generate filtered requirements at ${SELECTED_REQUIREMENTS}"
    return
  fi

  awk \
    -v profile="${PROFILE}" \
    -v no_jupyter="$((1 - INSTALL_JUPYTER))" \
    '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      {
        if (profile == "lite" && $0 ~ /# *full-only/) next
        if (no_jupyter == 1 && $0 ~ /# *jupyter/) next
        gsub(/[[:space:]]+#.*/, "", $0)
        print
      }
    ' "${REQUIREMENTS_FILE}" > "${SELECTED_REQUIREMENTS}"

  if [[ ! -s "${SELECTED_REQUIREMENTS}" ]]; then
    die "Filtered requirements file is empty: ${SELECTED_REQUIREMENTS}"
  fi
}

patch_openmp_sysconfig_if_needed() {
  if [[ "${PROFILE}" != "full" ]]; then
    return
  fi

  local stdlib_dir
  local -a matches=()
  local file_path

  stdlib_dir="$("${PYTHON_BIN}" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"

  while IFS= read -r file_path; do
    matches+=("${file_path}")
  done < <(find "${stdlib_dir}" -maxdepth 2 -type f -name '*sysconfigdata*.py')

  if (( ${#matches[@]} == 0 )); then
    warn "No sysconfigdata file found in ${stdlib_dir}; skipping OpenMP patch."
    return
  fi

  if (( ${#matches[@]} > 1 )); then
    warn "Found multiple sysconfigdata files; skipping patch to avoid unsafe mutation."
    printf '%s\n' "${matches[@]}" >&2
    return
  fi

  file_path="${matches[0]}"

  if ! grep -q -- '-fno-openmp-implicit-rpath' "${file_path}"; then
    log "OpenMP flag not present in ${file_path}; patch not required."
    return
  fi

  log "OpenMP lines before patch:"
  grep -n -- '-fno-openmp-implicit-rpath' "${file_path}" || true

  run_cmd mkdir -p "${BACKUP_DIR}"
  PATCH_BACKUP="${BACKUP_DIR}/$(basename "${file_path}").$(date +%Y%m%d-%H%M%S).bak"
  PATCHED_FILE="${file_path}"
  run_cmd cp -- "${file_path}" "${PATCH_BACKUP}"

  if (( DRY_RUN )); then
    log "Dry run: patch would be applied to ${file_path}; backup path ${PATCH_BACKUP}"
    return
  fi

  sed -i 's|-fno-openmp-implicit-rpath||g' "${file_path}"

  log "OpenMP lines after patch:"
  grep -n -- '-fno-openmp-implicit-rpath' "${file_path}" || true

  if grep -q -- '-fno-openmp-implicit-rpath' "${file_path}"; then
    die "OpenMP patch verification failed for ${file_path}"
  fi

  log "OpenMP patch applied to ${file_path}; backup: ${PATCH_BACKUP}"
  log "Restore command: cp -- \"${PATCH_BACKUP}\" \"${file_path}\""
}

install_python_dependencies() {
  local pip_args=(install)

  if (( KEEP_CACHE == 0 )); then
    pip_args+=(--no-cache-dir)
  fi

  run_cmd "${PYTHON_BIN}" -m pip "${pip_args[@]}" --upgrade pip setuptools wheel
  run_cmd "${PYTHON_BIN}" -m pip "${pip_args[@]}" -r "${SELECTED_REQUIREMENTS}" -c "${CONSTRAINTS_FILE}"
}

python_has_module() {
  "${PYTHON_BIN}" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('${1}') else 1)"
}

install_statsmodels_for_full_profile() {
  if [[ "${PROFILE}" != "full" ]]; then
    return
  fi

  if python_has_module "statsmodels"; then
    log "statsmodels is already available in ${PYTHON_BIN}"
    return
  fi

  if is_pkg_available python-statsmodels; then
    log "Installing statsmodels from Termux package: python-statsmodels"
    install_missing_pkgs python-statsmodels
  else
    warn "Termux package python-statsmodels not available on this mirror."
  fi

  if python_has_module "statsmodels"; then
    return
  fi

  local pip_args=(install)
  local api_level=""
  local -a build_cmd=()

  if (( KEEP_CACHE == 0 )); then
    pip_args+=(--no-cache-dir)
  fi

  if command_exists getprop; then
    api_level="$(getprop ro.build.version.sdk 2>/dev/null || true)"
  fi

  if [[ -n "${api_level}" ]]; then
    build_cmd=(
      env
      "CFLAGS=-include complex.h -U__ANDROID_API__ -D__ANDROID_API__=${api_level}"
      "MATHLIB=m"
      "LDFLAGS=-lm"
    )
  else
    build_cmd=(
      env
      "CFLAGS=-include complex.h"
      "MATHLIB=m"
      "LDFLAGS=-lm"
    )
  fi

  warn "Falling back to pip source build for statsmodels==${STATSMODELS_VERSION}."
  warn "Using CFLAGS workaround for missing cpow/cpowf declarations on some Termux toolchains."
  run_cmd "${build_cmd[@]}" "${PYTHON_BIN}" -m pip "${pip_args[@]}" --no-build-isolation "statsmodels==${STATSMODELS_VERSION}" -c "${CONSTRAINTS_FILE}"

  if ! python_has_module "statsmodels"; then
    die "statsmodels installation finished but import still fails."
  fi
}

write_install_reports() {
  if (( DRY_RUN )); then
    log "Dry run: skipping report generation"
    return
  fi

  "${PYTHON_BIN}" -m pip freeze > "${FREEZE_OUTPUT}"

  {
    printf 'timestamp_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "${PYTHON_BIN}" --version
    uname -a
    if command_exists termux-info; then
      termux-info
    else
      printf 'termux-info: unavailable\n'
    fi
  } > "${ENV_OUTPUT}"

  log "Wrote ${FREEZE_OUTPUT}"
  log "Wrote ${ENV_OUTPUT}"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --lite)
        PROFILE="lite"
        ;;
      --full)
        PROFILE="full"
        ;;
      --no-jupyter)
        INSTALL_JUPYTER=0
        ;;
      --venv)
        shift
        if (( $# == 0 )); then
          die "--venv requires a path"
        fi
        VENV_PATH="$1"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --clean)
        CLEAN_ONLY=1
        ;;
      --with-upgrade)
        WITH_UPGRADE=1
        ;;
      --keep-cache)
        KEEP_CACHE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  if (( CLEAN_ONLY )); then
    clean_generated_artifacts
    log "Clean completed."
    exit 0
  fi

  require_commands pkg dpkg apt-cache find sed grep awk uname

  if (( KEEP_CACHE )); then
    run_cmd mkdir -p "${BUILD_DIR}/pip-cache"
    export PIP_CACHE_DIR="${BUILD_DIR}/pip-cache"
    log "Using pip cache at ${PIP_CACHE_DIR}"
  fi

  if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    die "Missing ${REQUIREMENTS_FILE}"
  fi

  if [[ ! -f "${CONSTRAINTS_FILE}" ]]; then
    die "Missing ${CONSTRAINTS_FILE}"
  fi

  log "Profile: ${PROFILE}"
  log "Install JupyterLab: ${INSTALL_JUPYTER}"
  log "Dry run: ${DRY_RUN}"
  log "Virtual env: ${VENV_PATH:-<system>}"

  run_cmd pkg update -y

  if (( WITH_UPGRADE )); then
    run_cmd pkg upgrade -y
  fi

  install_missing_pkgs "${BASE_PKGS[@]}"
  install_missing_pkgs "${BUILD_PKGS[@]}"
  install_missing_pkgs "${LITE_PKGS[@]}"

  require_commands python

  if [[ "${PROFILE}" == "full" ]]; then
    install_missing_pkgs "${FULL_EXTRA_PKGS[@]}"

    if ! is_pkg_installed x11-repo; then
      run_cmd pkg install -y x11-repo
      run_cmd pkg update -y
    fi

    install_missing_pkgs opencv-python
  fi

  prepare_python_context
  build_selected_requirements
  patch_openmp_sysconfig_if_needed
  install_python_dependencies
  install_statsmodels_for_full_profile
  write_install_reports

  log "Installation finished."
  log "Run validation with: ${PYTHON_BIN} ${SCRIPT_DIR}/scientific-libraries-test.py"
}

main "$@"
