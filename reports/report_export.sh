#!/usr/bin/env bash
# ==============================================================================
# render_pdf.sh - Universal, Cross-Distro LaTeX to PDF Compilation Pipeline
# Supports: Arch, Endeavour, Ubuntu, Debian, Fedora, openSUSE, Alpine, & WSL1/WSL2
# Source of truth: .tex source files are left strictly untouched
# ==============================================================================

set -euo pipefail

# 1. Terminal Styling & Logging
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"

log_info() { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*"; }
log_warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2; }

# 2. Universal Environment Fixes
# Prevents Arch/EndeavourOS libpaper syntax crash with xdvipdfmx while being safe on Debian/Fedora/WSL
export PAPERSIZE="a4"

# 3. Help & Usage
print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [FILE.tex | FILE]

Arguments:
  FILE                  Path to target .tex file (with or without .tex extension).
                        Defaults to 'report.tex' if present in the current directory.

Options:
  --clean               Remove auxiliary files (.aux, .toc, .out, .log) after build.
  --engine <ENGINE>     Explicitly choose compiler (default: xelatex).
  --timeout <SECONDS>   Set compilation timeout per pass (default: 90).
  -h, --help            Show this help message.

Examples:
  $(basename "$0")                          # Renders report.tex by default
  $(basename "$0") custom_doc.tex           # Renders custom_doc.tex
  $(basename "$0") path/to/thesis           # Renders path/to/thesis.tex
  $(basename "$0") --clean my_slides.tex    # Renders and cleans aux files
EOF
}

# 4. Argument Parsing
TARGET_ARG=""
CLEAN_AUX=false
CHOSEN_ENGINE="xelatex"
TIMEOUT_SEC=90

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    print_usage
    exit 0
    ;;
  --clean)
    CLEAN_AUX=true
    shift
    ;;
  --engine)
    CHOSEN_ENGINE="$2"
    shift 2
    ;;
  --timeout)
    TIMEOUT_SEC="$2"
    shift 2
    ;;
  -*)
    log_error "Unknown option: $1"
    print_usage
    exit 1
    ;;
  *)
    if [[ -z "${TARGET_ARG}" ]]; then
      TARGET_ARG="$1"
    else
      log_error "Multiple target files specified: '${TARGET_ARG}' and '$1'"
      exit 1
    fi
    shift
    ;;
  esac
done

# 5. Resolve Target File & Directories
if [[ -z "${TARGET_ARG}" ]]; then
  if [[ -f "report.tex" ]]; then
    TARGET_ARG="report.tex"
  else
    # Search for any single .tex file in the current working directory
    TEX_COUNT=$(find . -maxdepth 1 -name "*.tex" | wc -l)
    if [[ "${TEX_COUNT}" -eq 1 ]]; then
      TARGET_ARG="$(find . -maxdepth 1 -name "*.tex" | head -n 1)"
    else
      log_error "No target specified and 'report.tex' not found in current directory."
      if [[ "${TEX_COUNT}" -gt 1 ]]; then
        log_info "Available .tex files in current directory:"
        find . -maxdepth 1 -name "*.tex" -exec basename {} \; | sed 's/^/  - /'
      fi
      print_usage
      exit 1
    fi
  fi
fi

# Append .tex if omitted
if [[ "${TARGET_ARG}" != *.tex ]]; then
  if [[ -f "${TARGET_ARG}.tex" ]]; then
    TARGET_ARG="${TARGET_ARG}.tex"
  fi
fi

if [[ ! -f "${TARGET_ARG}" ]]; then
  log_error "Target LaTeX file does not exist: '${TARGET_ARG}'"
  exit 1
fi

# Canonical absolute paths
ABS_TEX_FILE="$(cd "$(dirname "${TARGET_ARG}")" && pwd)/$(basename "${TARGET_ARG}")"
DOC_DIR="$(dirname "${ABS_TEX_FILE}")"
BASE_NAME="$(basename "${ABS_TEX_FILE}" .tex)"
PDF_OUTPUT="${DOC_DIR}/${BASE_NAME}.pdf"

# 6. Pre-flight Compiler Check
if ! command -v "${CHOSEN_ENGINE}" >/dev/null 2>&1; then
  log_error "Compiler '${CHOSEN_ENGINE}' not found in PATH."
  log_info "Please install LaTeX with XeLaTeX support (e.g. 'texlive-xetex' on Debian/Ubuntu/Fedora/Arch)."
  exit 1
fi

# 7. Cross-Distro & WSL Font Resolution (Zero Global Package Installs)
# Handles Times New Roman across Ubuntu, Debian, Fedora, Arch, Alpine, and WSL1/WSL2
ensure_cross_distro_fonts() {
  # Check if fontconfig already recognizes "Times New Roman"
  if command -v fc-list >/dev/null 2>&1; then
    if fc-list : family | grep -qEi "^(Times New Roman)$"; then
      return 0
    fi
  fi

  log_warn "Font 'Times New Roman' not detected in system fontconfig."
  log_info "Running cross-distro font discovery & localized provisioning..."

  local user_font_dir="${HOME}/.local/share/fonts/TimesNewRoman"
  mkdir -p "${user_font_dir}"
  local fonts_found=false

  # Scenario A: WSL1 / WSL2 or Dual-Boot environment with Windows fonts mounted
  local win_font_candidates=(
    "/mnt/c/Windows/Fonts"
    "/mnt/c/WINDOWS/Fonts"
    "/c/Windows/Fonts"
    "/c/WINDOWS/Fonts"
    "/mnt/Acer/Windows/Fonts"
    "/mnt/d/Windows/Fonts"
  )

  for win_dir in "${win_font_candidates[@]}"; do
    if [[ -d "${win_dir}" ]] && [[ -r "${win_dir}" ]]; then
      # Check for readable times.ttf or times*.ttf
      if compgen -G "${win_dir}/[Tt][Ii][Mm][Ee][Ss]*.ttf" >/dev/null 2>&1; then
        log_info "Detected Windows host fonts in '${win_dir}'. Linking/copying locally..."
        for font_path in "${win_dir}"/[Tt][Ii][Mm][Ee][Ss]*.ttf; do
          if [[ -f "${font_path}" ]] && [[ -r "${font_path}" ]]; then
            cp -n "${font_path}" "${user_font_dir}/" 2>/dev/null || true
            fonts_found=true
          fi
        done
        if [[ "${fonts_found}" == true ]]; then
          break
        fi
      fi
    fi
  done

  # Scenario B: Native Linux Distros (Ubuntu/Debian, Fedora, Arch, openSUSE)
  # Synthesize metric-compatible Times New Roman from Liberation Serif via Python fontTools
  if [[ "${fonts_found}" == false ]] && command -v python3 >/dev/null 2>&1; then
    python3 - <<'EOF' || true
import os
import sys

try:
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit(0)

# Dynamically query fontconfig for Liberation Serif file path on any distro
src_dir = None
try:
    import subprocess
    out = subprocess.check_output(["fc-list", "Liberation Serif", "file"], text=True)
    for line in out.strip().split("\n"):
        p = line.split(":")[0].strip()
        if os.path.isfile(p):
            src_dir = os.path.dirname(p)
            break
except Exception:
    pass

# Fallback known paths across distros
if not src_dir:
    for cand in [
        "/usr/share/fonts/liberation",
        "/usr/share/fonts/truetype/liberation",
        "/usr/share/fonts/liberation-serif",
        "/usr/share/fonts/TTF",
        "/usr/share/fonts"
    ]:
        if os.path.isfile(os.path.join(cand, "LiberationSerif-Regular.ttf")):
            src_dir = cand
            break

if not src_dir:
    sys.exit(0)

target_dir = os.path.expanduser("~/.local/share/fonts/TimesNewRoman")
os.makedirs(target_dir, exist_ok=True)

font_map = {
    "LiberationSerif-Regular.ttf": ("Times New Roman", "Regular", "TimesNewRomanPSMT"),
    "LiberationSerif-Bold.ttf": ("Times New Roman", "Bold", "TimesNewRomanPS-BoldMT"),
    "LiberationSerif-Italic.ttf": ("Times New Roman", "Italic", "TimesNewRomanPS-ItalicMT"),
    "LiberationSerif-BoldItalic.ttf": ("Times New Roman", "Bold Italic", "TimesNewRomanPS-BoldItalicMT"),
}

for src_name, (fam, subfam, postscript) in font_map.items():
    src_path = os.path.join(src_dir, src_name)
    if not os.path.isfile(src_path):
        continue
    out_file = os.path.join(target_dir, f"{postscript}.ttf")
    if os.path.isfile(out_file):
        continue
    font = TTFont(src_path)
    name_table = font['name']
    for rec in name_table.names:
        if rec.nameID == 1:
            rec.string = fam.encode(rec.getEncoding())
        elif rec.nameID == 2:
            rec.string = subfam.encode(rec.getEncoding())
        elif rec.nameID == 4:
            rec.string = f"{fam} {subfam}".encode(rec.getEncoding())
        elif rec.nameID == 6:
            rec.string = postscript.encode(rec.getEncoding())
        elif rec.nameID in (16, 21):
            rec.string = fam.encode(rec.getEncoding())
    font.save(out_file)
EOF
  fi

  # Scenario C: Fontconfig User Alias Fallback
  local fc_user_conf="${HOME}/.config/fontconfig/conf.d/99-times-new-roman-alias.conf"
  mkdir -p "$(dirname "${fc_user_conf}")"
  if [[ ! -f "${fc_user_conf}" ]]; then
    cat <<'EOF' >"${fc_user_conf}"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test qual="any" name="family"><string>Times New Roman</string></test>
    <edit name="family" mode="assign" binding="same"><string>Liberation Serif</string></edit>
  </match>
</fontconfig>
EOF
  fi

  # Update user font caches
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "${HOME}/.local/share/fonts" >/dev/null 2>&1 || true
    mkdir -p "${HOME}/.fonts"
    cp -n "${user_font_dir}"/*.ttf "${HOME}/.fonts/" 2>/dev/null || true
    fc-cache -f "${HOME}/.fonts" >/dev/null 2>&1 || true
  fi

  log_success "Cross-distro font configuration updated."
}

ensure_cross_distro_fonts

log_info "Compiling: ${ABS_TEX_FILE}"
log_info "Working directory: ${DOC_DIR}"
log_info "LaTeX Engine: $(${CHOSEN_ENGINE} --version | head -n 1)"

START_TIME=$(date +%s)
BUILD_LOG="${DOC_DIR}/${BASE_NAME}.build.log"

# 8. Multi-Pass Compilation Execution
# Execute within DOC_DIR so that relative graphics/inputs resolve identically across all OSes
compile_pass() {
  local pass_num="$1"
  local total_passes="$2"
  log_info "Running ${CHOSEN_ENGINE} pass ${pass_num}/${total_passes}..."

  (
    cd "${DOC_DIR}"
    timeout "${TIMEOUT_SEC}" "${CHOSEN_ENGINE}" \
      -interaction=nonstopmode \
      -halt-on-error \
      -output-directory="${DOC_DIR}" \
      "${ABS_TEX_FILE}" >"${BUILD_LOG}" 2>&1
  ) || {
    local exit_code=$?
    log_error "${CHOSEN_ENGINE} compilation failed on pass ${pass_num} (Exit code: ${exit_code})!"
    echo "------------------- TAIL OF BUILD LOG -------------------"
    tail -n 45 "${BUILD_LOG}"
    echo "--------------------------------------------------------"
    exit ${exit_code}
  }
}

compile_pass 1 2
compile_pass 2 2

# Supplementary pass 3 if references or table of contents shifted
MAIN_LOG="${DOC_DIR}/${BASE_NAME}.log"
if grep -q "Rerun to get cross-references right" "${MAIN_LOG}" 2>/dev/null ||
  grep -q "Rerun to get /PageLabels entry" "${MAIN_LOG}" 2>/dev/null ||
  grep -q "Rerun to get outlines right" "${MAIN_LOG}" 2>/dev/null; then
  log_info "Cross-references updated. Running supplementary pass 3/3..."
  compile_pass 3 3
fi

# 9. Output Verification
if [[ -f "${PDF_OUTPUT}" && -s "${PDF_OUTPUT}" ]]; then
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  FILE_SIZE=$(stat -c%s "${PDF_OUTPUT}" 2>/dev/null || stat -f%z "${PDF_OUTPUT}" 2>/dev/null || echo "Unknown")
  PAGE_COUNT=$(pdfinfo "${PDF_OUTPUT}" 2>/dev/null | awk '/^Pages:/ {print $2}' || echo "N/A")

  log_success "PDF generated successfully!"
  log_info "Output artifact: ${PDF_OUTPUT}"
  log_info "Page count: ${PAGE_COUNT} pages"
  log_info "Artifact size: ${FILE_SIZE} bytes"
  log_info "Elapsed time: ${DURATION}s"
else
  log_error "Compilation completed but '${PDF_OUTPUT}' is missing or empty."
  exit 1
fi

# 10. Cleanup
rm -f "${BUILD_LOG}"

if [[ "${CLEAN_AUX}" == true ]]; then
  log_info "Cleaning auxiliary files (--clean specified)..."
  rm -f "${DOC_DIR}/${BASE_NAME}.aux" \
    "${DOC_DIR}/${BASE_NAME}.toc" \
    "${DOC_DIR}/${BASE_NAME}.out" \
    "${DOC_DIR}/${BASE_NAME}.log"
fi

log_success "Process finished successfully."
