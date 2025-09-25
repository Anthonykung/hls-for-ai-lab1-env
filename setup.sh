#!/bin/bash

# @file   arc.sh
# @author Anthony Kung <hi@anth.dev> (anth.dev)
# @date   Created on August 25 2025, 18:40 -07:00

# ARC: Anthonian Runtime Configurator
# - Linux-only setup: Python env (conda or venv), CPU-only PyTorch, and toolchain checks.
# - Venv path: verify (do NOT install) host build tools at minimum versions.
# - Conda path: install build tools from conda-forge with version floors.
# - requirements.txt installs will NOT override torch/vision/audio installed by this script.
# - If conda setup fails at any point, automatically falls back to venv.

set -euo pipefail

# --- ARC startup printout ---
echo "============================================"
echo "  ARC (Anthonian Runtime Configurator)"
echo "============================================"
echo "Started: $(date)"
echo "Script: $0"
echo "Arguments: $@"
echo "============================================"

# ================================
#            CONSTANTS
# ================================
# Python & package versions
PY_VERSION="3.11"
PIP_TOOLS_VERSION=""          # e.g. "7.4.1" or empty for latest

# PyTorch (CPU-only) versions; empty = latest compatible from CPU index
TORCH_VERSION=""
TORCHVISION_VERSION=""
TORCHAUDIO_VERSION=""

# Environment defaults
ENV_NAME="arc_env"            # conda environment name
ENV_DIR=".venv"               # venv directory

# Logging & checks
LOG_FILE="install.log"
MIN_FREE_MB=1500

# Minimum toolchain versions (used for venv checks and conda floors)
# Use semantic versions that 'sort -V' understands.
MAKE_MIN="4.3"
GCC_MIN="11.5"
GXX_MIN="11.5"
CLANG_MIN="19.1"              # used only for version check fallback/diagnostic
CMAKE_MIN="3.26"

# pkg-config / pkgconf floors:
# - Linux distros ship 'pkgconf' and map 'pkg-config', reporting 1.x.y
# - conda-forge ships GNU 'pkg-config' 0.29.x
PKG_CONFIG_MIN_UPSTREAM="0.29.2"   # upstream 'pkg-config' (GNU) floor
PKGCONF_MIN="1.7.0"                # 'pkgconf' floor

# Conda package floors (string constraints). Leave empty to skip pin.
# Note: gcc/gxx use platform packages on Linux.
CONDA_MAKE_FLOOR=">=${MAKE_MIN}"
CONDA_CMAKE_FLOOR=">=${CMAKE_MIN}"
CONDA_PKG_CONFIG_FLOOR=">=${PKG_CONFIG_MIN_UPSTREAM}"  # conda-forge provides pkg-config 0.29.x
CONDA_GCC_FLOOR=">=${GCC_MIN}"
CONDA_GXX_FLOOR=">=${GXX_MIN}"

# Manual selection precedence:
# 1) CLI flags: --conda / --venv
# 2) ENV var:  ENV_MANAGER=conda|venv
# 3) Auto-detect: conda present → conda; else venv
ENV_MANAGER_DEFAULT=""
# ================================

# -------------- helpers --------------
say() { printf "%s\n" "$*"; }
note() { say "💡  $*"; }
step() { say "⚙️  $*"; }
ok()   { say "✅ $*"; }
warn() { say "⚠️  $*"; }
header(){ say "============================================"; say "  $*"; say "============================================"; }

usage() {
  cat <<EOF
NAME
  ARC (Anthonian Runtime Configurator) — Linux setup for Python environment (conda or venv) with CPU-only PyTorch

SYNOPSIS
  $0 [OPTIONS]

DESCRIPTION
  ARC (Anthonian Runtime Configurator) creates and configures a Python environment on Linux. Installs CPU-only PyTorch and dependencies.
  • Linux-only (errors out on non-Linux)
  • If using venv: verifies minimum build tools (no system installs)
  • If using conda: installs build tools from conda-forge
  • requirements.txt will not override already-installed torch packages
  • If conda setup fails at any point, ARC automatically falls back to venv.

OPTIONS
  --conda
      Prefer conda environment manager (ARC will fall back to venv on failure).
  --venv
      Force Python venv (disables conda attempt and fallback).
  --python <X.Y>
      Python version to use (default from constants section).
  --name <env-name>
      Conda environment name (default from constants).
  --venv-dir <path>
      Venv directory (default from constants).
  --help, -h
      Show this help and exit.

ENVIRONMENT
  ENV_MANAGER=conda|venv
      Preference if no --conda/--venv is provided (ARC still falls back to venv if conda fails).

MINIMUM TOOL VERSIONS (edit at top)
  make >= ${MAKE_MIN}
  gcc  >= ${GCC_MIN}
  g++  >= ${GXX_MIN}
  cmake >= ${CMAKE_MIN}
  pkg-config: one of the following must hold
    - pkgconf >= ${PKGCONF_MIN}    (many Linux distros map 'pkg-config' → pkgconf)
    - pkg-config >= ${PKG_CONFIG_MIN_UPSTREAM}  (GNU upstream; conda-forge ships this)

QUICK REFERENCE
  Conda:
    conda activate <name>
    conda list
    conda install <pkg>         # add packages
    conda remove -n <name> --all
  Venv (bash/zsh):
    source <venv-dir>/bin/activate
    pip install <pkg>
    deactivate

EXAMPLES
  $0
  $0 --conda --python 3.11
  $0 --venv --venv-dir .env
  ENV_MANAGER=venv $0

EOF
}

# -------------- early guards --------------
if [ -z "${BASH_VERSION:-}" ]; then
  echo "⚠️  Please run with bash: bash $0 $*" >&2
  exit 1
fi

# Log rotation (keep last run as .1), then truncate
if [ -f "${LOG_FILE}" ]; then
  mv -f "${LOG_FILE}" "${LOG_FILE}.1" || true
fi
: > "${LOG_FILE}"

# -------------- utilities --------------
# Compare two versions (semver-ish). Returns 0 if v1 >= v2.
ver_ge() {
  # usage: ver_ge "1.2.3" "1.2"
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Extract the first version-like token from a command's --version output.
get_version() {
  # usage: get_version gcc "--version"
  local cmd="$1"; shift
  "$cmd" "$@" 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -n1
}

conda_safe() {
  set +u
  conda "$@"
  local rc=$?
  set -u
  return $rc
}

cleanup_conda() {
  if [[ -n "${CONDA_PREFIX:-}" ]]; then
    set +u
    conda deactivate || true
    set -u
  fi
}
trap cleanup_conda EXIT
trap 'warn "Something failed. Check ${LOG_FILE} for details."' ERR

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    warn "Required tool '$name' not found in PATH."
    return 1
  fi
  return 0
}

check_free_space() {
  local need_mb="${MIN_FREE_MB}"
  local avail
  avail="$(df -Pm . | awk 'NR==2 {print $4}')"
  if [ "${avail:-0}" -lt "$need_mb" ]; then
    warn "Low disk space: ${avail}MB available, ~${need_mb}MB recommended."
  fi
}

# Prefer pkgconf if present; otherwise detect by version heuristic
detect_pkgconfig_provider() {
  # Echoes "pkgconf" or "pkg-config" or "unknown"
  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  if command -v pkgconf >/dev/null 2>&1; then
    # If both exist, we prefer pkgconf deterministically
    echo "pkgconf"
    return
  fi
  local pc_ver
  pc_ver="$(get_version pkg-config --version || echo)"
  if [[ -z "${pc_ver}" ]]; then
    echo "unknown"
    return
  fi
  if ver_ge "${pc_ver}" "1.0.0"; then
    echo "pkgconf"
  else
    echo "pkg-config"
  fi
}

check_pkg_config_with_provider() {
  if ! require_cmd pkg-config; then
    warn "pkg-config not found."
    return 1
  fi
  local provider pc_ver
  provider="$(detect_pkgconfig_provider)"
  pc_ver="$(get_version pkg-config --version || echo 0)"
  case "${provider}" in
    pkgconf)
      if ver_ge "${pc_ver}" "${PKGCONF_MIN}"; then
        ok "pkgconf (via pkg-config) ${pc_ver} (>= ${PKGCONF_MIN})"
        return 0
      else
        warn "pkgconf (via pkg-config) ${pc_ver} (< ${PKGCONF_MIN})"
        return 1
      fi
      ;;
    pkg-config)
      if ver_ge "${pc_ver}" "${PKG_CONFIG_MIN_UPSTREAM}"; then
        ok "pkg-config ${pc_ver} (>= ${PKG_CONFIG_MIN_UPSTREAM})"
        return 0
      else
        warn "pkg-config ${pc_ver} (< ${PKG_CONFIG_MIN_UPSTREAM})"
        return 1
      fi
      ;;
    *)
      warn "Unable to determine pkg-config provider; reporting version ${pc_ver}"
      if ver_ge "${pc_ver}" "${PKGCONF_MIN}" || ver_ge "${pc_ver}" "${PKG_CONFIG_MIN_UPSTREAM}"; then
        ok "pkg-config ${pc_ver} (meets a known floor)"
        return 0
      else
        warn "pkg-config ${pc_ver} not meeting known floors (pkgconf ${PKGCONF_MIN} or pkg-config ${PKG_CONFIG_MIN_UPSTREAM})."
        return 1
      fi
      ;;
  esac
}

verify_build_basics_with_versions() {
  local ok_all=true

  # make
  if require_cmd make; then
    local v; v="$(get_version make --version || echo 0)"
    if ver_ge "${v}" "${MAKE_MIN}"; then ok "make ${v} (>= ${MAKE_MIN})"
    else warn "make ${v} (< ${MAKE_MIN})"; ok_all=false; fi
  else ok_all=false; fi

  # gcc
  if require_cmd gcc; then
    local v; v="$(get_version gcc --version || echo 0)"
    if ver_ge "${v}" "${GCC_MIN}"; then ok "gcc ${v} (>= ${GCC_MIN})"
    else warn "gcc ${v} (< ${GCC_MIN})"; ok_all=false; fi
  else ok_all=false; fi

  # g++
  if require_cmd g++; then
    local v; v="$(get_version g++ --version || echo 0)"
    if ver_ge "${v}" "${GXX_MIN}"; then ok "g++ ${v} (>= ${GXX_MIN})"
    else warn "g++ ${v} (< ${GXX_MIN})"; ok_all=false; fi
  else ok_all=false; fi

  # cmake
  if require_cmd cmake; then
    local v; v="$(get_version cmake --version || echo 0)"
    if ver_ge "${v}" "${CMAKE_MIN}"; then ok "cmake ${v} (>= ${CMAKE_MIN})"
    else warn "cmake ${v} (< ${CMAKE_MIN})"; ok_all=false; fi
  else ok_all=false; fi

  # pkg-config / pkgconf (handles both providers)
  if ! check_pkg_config_with_provider; then ok_all=false; fi

  $ok_all || { warn "Build tool prerequisites missing or too old. Please upgrade to meet minimums."; return 1; }
  ok "All required build tools meet minimum versions."
}

# ---------- shared installers ----------
install_cpu_torch() {
  local TORCH_INDEX_OPT="--index-url https://download.pytorch.org/whl/cpu"
  local pkgs=()
  if [[ -n "${TORCH_VERSION}" ]]; then pkgs+=("torch==${TORCH_VERSION}"); else pkgs+=("torch"); fi
  if [[ -n "${TORCHVISION_VERSION}" ]]; then pkgs+=("torchvision==${TORCHVISION_VERSION}"); else pkgs+=("torchvision"); fi
  if [[ -n "${TORCHAUDIO_VERSION}" ]]; then pkgs+=("torchaudio==${TORCHAUDIO_VERSION}"); else pkgs+=("torchaudio"); fi
  pip install ${TORCH_INDEX_OPT} "${pkgs[@]}" --quiet >>"${LOG_FILE}" 2>&1
}

post_python_setup() {
  step "Upgrading pip..."
  python -m pip install --upgrade pip --quiet >>"${LOG_FILE}" 2>&1
  ok "pip upgraded."

  step "Installing pip-tools..."
  if [[ -n "${PIP_TOOLS_VERSION}" ]]; then
    pip install "pip-tools==${PIP_TOOLS_VERSION}" --quiet >>"${LOG_FILE}" 2>&1
  else
    pip install pip-tools --quiet >>"${LOG_FILE}" 2>&1
  fi
  ok "pip-tools installed."

  step "Installing PyTorch (CPU-only wheels)..."
  if ! install_cpu_torch; then
    warn "PyTorch CPU install failed from official index. Retrying from PyPI..."
    if [[ -n "${TORCH_VERSION}" ]]; then pip install "torch==${TORCH_VERSION}" --quiet >>"${LOG_FILE}" 2>&1 || true
    else pip install torch --quiet >>"${LOG_FILE}" 2>&1 || true; fi
    if [[ -n "${TORCHVISION_VERSION}" ]]; then pip install "torchvision==${TORCHVISION_VERSION}" --quiet >>"${LOG_FILE}" 2>&1 || true
    else pip install torchvision --quiet >>"${LOG_FILE}" 2>&1 || true; fi
    if [[ -n "${TORCHAUDIO_VERSION}" ]]; then pip install "torchaudio==${TORCHAUDIO_VERSION}" --quiet >>"${LOG_FILE}" 2>&1 || true
    else pip install torchaudio --quiet >>"${LOG_FILE}" 2>&1 || true; fi
  fi
  ok "PyTorch (CPU-only) installed."

  # Freeze torch* versions to prevent requirements from overriding them
  CONSTRAINTS_FILE="$(mktemp)"
  python - <<'PY' >"${CONSTRAINTS_FILE}" 2>>"${LOG_FILE}"
import importlib
for p in ("torch","torchvision","torchaudio"):
  try:
    m = importlib.import_module(p)
    v = getattr(m, "__version__", None)
    if v:
      print(f"{p}=={v}")
  except Exception:
    pass
PY
  note "Pinned torch packages: $(tr '\n' ' ' < "${CONSTRAINTS_FILE}")"

  if [ -f "requirements.txt" ]; then
    step "Resolving + installing from requirements.txt (will not override torch packages)..."
    TMP_REQ="$(mktemp)"
    if ! pip-compile requirements.txt --output-file="${TMP_REQ}" --quiet --strip-extras >>"${LOG_FILE}" 2>&1; then
      warn "pip-compile failed; falling back to raw requirements.txt"
      cp requirements.txt "${TMP_REQ}"
    fi
    pip install -r "${TMP_REQ}" --constraint "${CONSTRAINTS_FILE}" --quiet >>"${LOG_FILE}" 2>&1
    rm -f "${TMP_REQ}"
    ok "Additional packages installed with torch safeguarded."
  else
    note "No requirements.txt found — skipping extra Python deps."
  fi
}

verify_python_stack() {
  header "🔍 Verifying Python stack"
  python - <<'PY'
import sys
try:
  import torch, numpy
  print(f"Python: {sys.version.split()[0]}")
  print(f"Torch: {torch.__version__}")
  print(f"CUDA available (should be False): {torch.cuda.is_available()}")
  print(f"CUDA version: {getattr(torch.version, 'cuda', None)}")
  print(f"Numpy: {numpy.__version__}")
  if torch.cuda.is_available():
    print("⚠️  Unexpected GPU detected:", torch.cuda.get_device_name(0))
  else:
    print("✅ CPU-only PyTorch confirmed.")
except Exception as e:
  print(f"⚠️  Verification error (Python stack): {e!r}")
PY
}

print_toolchains() {
  echo ""
  step "Toolchain versions (post-setup):"
  if command -v make >/dev/null 2>&1;   then make --version | head -n1 || true; else warn "make not found."; fi
  if command -v gcc  >/dev/null 2>&1;   then gcc  --version | head -n1 || true; else warn "gcc not found.";  fi
  if command -v g++  >/dev/null 2>&1;   then g++  --version | head -n1 || true; else warn "g++ not found.";  fi
  if command -v cmake >/dev/null 2>&1;  then cmake --version | head -n1 || true; else warn "cmake not found."; fi
  if command -v pkg-config >/dev/null 2>&1; then pkg-config --version | head -n1 || true; else warn "pkg-config not found."; fi
}

print_cheatsheet() {
  say ""
  header "📎 ARC Quick Reference"
  cat <<EOF
Conda (if selected)
  Activate:     conda activate ${ENV_NAME}
  Deactivate:   conda deactivate
  Add package:  conda install <package>
  List:         conda list
  Remove env:   conda remove -n ${ENV_NAME} --all -y

Venv (if selected)
  Activate:     source ${ENV_DIR}/bin/activate
  Deactivate:   deactivate
  Add package:  pip install <package>
  Freeze:       pip freeze > requirements.lock.txt
  Remove venv:  rm -rf ${ENV_DIR}

General
  Re-run setup: $0 [--conda|--venv] [--python ${PY_VERSION}] [--name ${ENV_NAME}] [--venv-dir ${ENV_DIR}]
  Help:         $0 --help
  Logs:         ${LOG_FILE} (previous: ${LOG_FILE}.1)
EOF
}

# ---------- conda/venv setup (with fallback) ----------
try_setup_conda() {
  # Returns 0 on success, non-zero on any failure; never exits the script.
  # Temporarily relax 'errexit' to catch failures and allow fallback.
  set +e

  step "Conda selected."
  if ! command -v conda >/dev/null 2>&1; then
    warn "conda command not found."
    set -e
    return 2
  fi

  local base; base="$(conda info --base 2>/dev/null)"
  if [[ -z "${base}" || ! -f "${base}/etc/profile.d/conda.sh" ]]; then
    warn "conda found but not initialized properly."
    set -e
    return 3
  fi
  # shellcheck disable=SC1091
  source "${base}/etc/profile.d/conda.sh"

  step "Creating conda environment '${ENV_NAME}' with Python ${PY_VERSION}..."
  conda_safe create -n "${ENV_NAME}" python="${PY_VERSION}" -y --quiet >>"${LOG_FILE}" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Failed to create conda env (rc=$rc)."
    set -e
    return 4
  fi
  ok "Conda environment created."

  say ""
  note "Activate:   conda activate ${ENV_NAME}"
  note "Deactivate: conda deactivate"
  say "🧹  Remove:   conda remove -n ${ENV_NAME} --all -y"
  say "--------------------------------------------"

  step "Activating env..."
  set +u; conda activate "${ENV_NAME}" >>"${LOG_FILE}" 2>&1; rc=$?; set -u
  if [[ $rc -ne 0 || -z "${CONDA_PREFIX:-}" || "${CONDA_PREFIX##*/}" != "${ENV_NAME}" ]]; then
    warn "Conda activation failed."
    set -e
    return 5
  fi
  ok "Activated conda env."

  step "Installing build tools via conda-forge (with version floors)..."
  conda_safe config --add channels conda-forge >>"${LOG_FILE}" 2>&1 || true
  conda_safe config --set channel_priority strict >>"${LOG_FILE}" 2>&1 || true

  local arch; arch="$(uname -m)"
  local CONDA_PKGS=( "make${CONDA_MAKE_FLOOR}" "cmake${CONDA_CMAKE_FLOOR}" "pkg-config${CONDA_PKG_CONFIG_FLOOR}" )
  if [[ "${arch}" == "x86_64" || "${arch}" == "aarch64" ]]; then
    CONDA_PKGS+=( "gcc_linux-64${CONDA_GCC_FLOOR}" "gxx_linux-64${CONDA_GXX_FLOOR}" )
  else
    CONDA_PKGS+=( "compilers" )
  fi

  conda_safe install -y -c conda-forge "${CONDA_PKGS[@]}" >>"${LOG_FILE}" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Build tool install via conda failed (rc=$rc)."
    set -e
    return 6
  fi
  ok "Build tools installed (conda)."

  set -e
  return 0
}

try_setup_venv() {
  # Returns 0 on success, non-zero otherwise; never exits the script here.
  set +e

  step "Using Python venv path..."
  local PYBIN="python${PY_VERSION}"
  if ! command -v "$PYBIN" >/dev/null 2>&1; then PYBIN="python3"; fi
  if ! command -v "$PYBIN" >/dev/null 2>&1; then PYBIN="python"; fi
  if ! command -v "$PYBIN" >/dev/null 2>&1; then
    warn "No suitable Python interpreter found!"
    say  "Please install Python ${PY_VERSION}+ and re-run."
    set -e
    return 2
  fi

  local REQ_MAJ REQ_MIN
  REQ_MAJ="$(echo "${PY_VERSION}" | cut -d. -f1)"
  REQ_MIN="$(echo "${PY_VERSION}" | cut -d. -f2)"
  "$PYBIN" -c "import sys; print(int(sys.version_info[:2] == (${REQ_MAJ}, ${REQ_MIN})))" | grep -q '^1$'
  if [[ $? -ne 0 ]]; then
    note "Requested Python ${PY_VERSION} not found; using $("$PYBIN" -c 'import sys; v=sys.version_info; print(f"python {v[0]}.{v[1]}")') for venv."
  fi

  step "Verifying minimum build tools (no installation will be attempted)..."
  if ! verify_build_basics_with_versions; then
    set -e
    return 3
  fi

  if ! "$PYBIN" -c 'import venv' >/dev/null 2>&1; then
    warn "Python 'venv' module is missing. Install your OS package for venv (e.g., python3-venv) and re-run."
    set -e
    return 4
  fi

  step "Using interpreter: $($PYBIN -c 'import sys; print(sys.executable)')"
  step "Creating venv at '${ENV_DIR}'..."
  "$PYBIN" -m venv "${ENV_DIR}" >>"${LOG_FILE}" 2>&1
  if [[ $? -ne 0 ]]; then
    warn "Failed to create venv at ${ENV_DIR}."
    set -e
    return 5
  fi
  ok "Virtual environment created."

  say ""
  note "Activate (bash/zsh): source ${ENV_DIR}/bin/activate"
  note "Deactivate:          deactivate"
  say "🧹  Remove:            rm -rf ${ENV_DIR}"
  say "--------------------------------------------"

  # shellcheck disable=SC1091
  source "${ENV_DIR}/bin/activate"
  if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    warn "Activation seems to have failed (VIRTUAL_ENV not set)."
    set -e
    return 6
  fi
  ok "Activated venv."

  set -e
  return 0
}

# -------------- arg parsing --------------
FORCE_CONDA=false
FORCE_VENV=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --conda)
      FORCE_CONDA=true
      shift
      ;;
    --venv)
      FORCE_VENV=true
      shift
      ;;
    --python)
      PY_VERSION="${2:-}"
      shift 2
      ;;
    --name)
      ENV_NAME="${2:-}"
      shift 2
      ;;
    --venv-dir)
      ENV_DIR="${2:-}"
      shift 2
      ;;
    *)
      warn "Unknown argument: $1"
      say "Use --help to see available options."
      exit 1
      ;;
  esac
done

# -------------- OS detect (Linux-only) --------------
OS="$(uname -s || echo unknown)"
if [[ "${OS}" != "Linux" ]]; then
  warn "This setup script supports Linux only. Detected: ${OS}"
  exit 1
fi

# -------------- sudo info --------------
have_sudo=true
if ! command -v sudo >/dev/null 2>&1; then
  have_sudo=false
elif ! sudo -n true >/dev/null 2>&1; then
  note "sudo may prompt for a password for some operations (conda installs do not require sudo)."
fi

check_free_space || true

header "🚀 Setting up Python (conda/venv) + CPU-only PyTorch + Toolchain (Linux)"
say "(logs will be saved in ${LOG_FILE})"
say ""

# -------------- choose env manager + fallback logic --------------
USE_CONDA=false
FALLBACK_USED=false

if $FORCE_VENV; then
  USE_CONDA=false
elif $FORCE_CONDA; then
  USE_CONDA=true
else
  case "${ENV_MANAGER:-${ENV_MANAGER_DEFAULT}}" in
    conda) USE_CONDA=true ;;
    venv)  USE_CONDA=false ;;
    "" )
      if command -v conda >/dev/null 2>&1; then USE_CONDA=true; else USE_CONDA=false; fi
      ;;
    * )
      warn "ENV_MANAGER must be 'conda' or 'venv' (got '${ENV_MANAGER}')."
      exit 1
      ;;
  esac
fi

# Attempt setup
if $USE_CONDA; then
  if ! try_setup_conda; then
    warn "Conda setup failed — attempting fallback to venv..."
    FALLBACK_USED=true
    if ! try_setup_venv; then
      warn "Fallback to venv also failed. See ${LOG_FILE} for details."
      exit 1
    fi
    USE_CONDA=false
    ok "Fallback to venv succeeded."
  fi
else
  if ! try_setup_venv; then
    warn "Venv setup failed."
    # If user forced venv, do not try conda. If not forced and conda exists, try conda as a secondary fallback.
    if $FORCE_VENV; then
      exit 1
    fi
    if command -v conda >/dev/null 2>&1; then
      warn "Attempting secondary fallback to conda..."
      FALLBACK_USED=true
      if ! try_setup_conda; then
        warn "Secondary fallback to conda failed. See ${LOG_FILE} for details."
        exit 1
      fi
      USE_CONDA=true
      ok "Secondary fallback to conda succeeded."
    else
      exit 1
    fi
  fi
fi

# -------------- Python deps + verification (common) --------------
post_python_setup
verify_python_stack

# -------------- Toolchain versions (post) --------------
print_toolchains

# -------------- Quick Reference Cheat Sheet --------------
print_cheatsheet

say ""
say "🎉  ARC setup complete!"
if $USE_CONDA; then
  if $FALLBACK_USED; then
    note "Environment: conda (${ENV_NAME}) — reached via fallback."
  else
    note "Environment: conda (${ENV_NAME})"
  fi
  note "Activate with: conda activate ${ENV_NAME}"
else
  if $FALLBACK_USED; then
    note "Environment: venv (${ENV_DIR}) — reached via fallback."
  else
    note "Environment: venv (${ENV_DIR})"
  fi
  note "Activate with: source ${ENV_DIR}/bin/activate"
fi
say "(see ${LOG_FILE} for details)"
say "Finished: $(date)"
header "🚀 Happy coding! 🚀"
