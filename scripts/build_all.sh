#!/usr/bin/env bash
set -euo pipefail
set -x

# One-shot builder: builds NTL + Barvinok (with ISL) into a local prefix,
# then builds upstream islpy with Barvinok enabled, renames the Python
# package to islpy_barvinok and the distribution to islpy-barvinok, and
# produces wheels in a local build directory. Optionally repairs wheels
# to vendor native libs if delocate/auditwheel are available.

# Configuration
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# Load centralized configuration
if [[ -f "$ROOT_DIR/config.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/config.sh"
fi
BUILD_ROOT=${BUILD_ROOT:-"$ROOT_DIR/build"}
PREFIX_DIR=${PREFIX_DIR:-"$BUILD_ROOT/prefix"}
SRC_DIR=${SRC_DIR:-"$BUILD_ROOT/src"}
WHEEL_DIR=${WHEEL_DIR:-"$BUILD_ROOT/wheelhouse"}
REPAIRED_DIR=${REPAIRED_DIR:-"$BUILD_ROOT/wheelhouse-repaired"}
# Resolve upstream islpy version: prefer env, else read from repo pyproject.toml
if [[ -z "${ISLPY_VERSION:-}" ]]; then
  ISLPY_VERSION=$(python - <<'PY'
import pathlib, re
txt = pathlib.Path('pyproject.toml').read_text(encoding='utf-8')
m = re.search(r"^version\s*=\s*\"([^\"]+)\"", txt, flags=re.M)
print(m.group(1) if m else "")
PY
)
fi
if [[ -z "${ISLPY_VERSION:-}" ]]; then
  echo "ERROR: Could not determine ISLPY_VERSION from pyproject.toml or env" >&2
  exit 1
fi
GMP_VER=${GMP_VER:-${GMP_VER}}
NTL_VER=${NTL_VER:-${NTL_VER}}
BARVINOK_GIT_REV=${BARVINOK_GIT_REV:-${BARVINOK_GIT_REV}}
NPROCS=${NPROCS:-$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}

mkdir -p "$BUILD_ROOT" "$PREFIX_DIR" "$SRC_DIR" "$WHEEL_DIR" "$REPAIRED_DIR"
export ISLPY_VERSION

# Derive base upstream islpy version (strip optional build suffix like "-1")
ISLPY_BASE_VERSION=${ISLPY_BASE_VERSION:-"${ISLPY_VERSION%%-*}"}
export ISLPY_BASE_VERSION

echo "Using BUILD_ROOT=$BUILD_ROOT"
echo "Using PREFIX_DIR=$PREFIX_DIR"
if [[ -d "$PREFIX_DIR/lib" && -f "$PREFIX_DIR/lib/libbarvinok.dylib" || -f "$PREFIX_DIR/lib/libbarvinok.so" ]]; then
  echo "Found cached prefix with Barvinok; skipping rebuild of GMP/NTL/Barvinok."
  SKIP_NATIVE_BUILD=1
else
  SKIP_NATIVE_BUILD=0
fi

# Ensure required build tools
ensure_autotools() {
  if command -v autoreconf >/dev/null 2>&1 && command -v libtoolize >/dev/null 2>&1 \
     && command -v aclocal >/dev/null 2>&1 && command -v automake >/dev/null 2>&1 \
     && command -v autoconf >/dev/null 2>&1; then
    return 0
  fi
  echo "Autotools not found; attempting to install."
  if command -v brew >/dev/null 2>&1; then
    brew update || true
    brew install autoconf automake libtool pkg-config || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y || true
    sudo apt-get install -y autoconf automake libtool pkg-config || true
  else
    echo "Please install autotools (autoconf automake libtool pkg-config) and re-run."
    exit 1
  fi
}

# Ensure Python build deps for islpy wheel
PYTHON_BIN=${PYTHON_BIN:-python3}
if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
  "$PYTHON_BIN" -m ensurepip --upgrade || true
fi
"$PYTHON_BIN" -m pip install --upgrade pip || true
"$PYTHON_BIN" -m pip install --upgrade build cmake ninja setuptools wheel || true
# Pre-install upstream islpy build dependencies to avoid PEP 517 build isolation
# failures on certain platforms (e.g., macOS arm64 Python 3.10) and speed up builds.
# Include transitive backend deps that may otherwise be built from sdist.
"$PYTHON_BIN" -m pip install --upgrade \
  scikit-build-core nanobind pcpp typing_extensions \
  tomli flit_core hatchling trove-classifiers calver || true

if [[ "$SKIP_NATIVE_BUILD" == 0 ]]; then
  # ------------------------------
  # Build GMP into local PREFIX_DIR
  # ------------------------------
  pushd "$SRC_DIR"
  curl -L -O https://ftp.gnu.org/gnu/gmp/gmp-"$GMP_VER".tar.xz || curl -L -O https://gmplib.org/download/gmp/gmp-"$GMP_VER".tar.xz
  tar xJf gmp-"$GMP_VER".tar.xz
  pushd gmp-"$GMP_VER"
  ./configure --prefix="$PREFIX_DIR" --enable-shared
  make -j"$NPROCS"
  make install
  popd
fi

if [[ "$SKIP_NATIVE_BUILD" == 0 ]]; then
  # ------------------------------
  # Build NTL into local PREFIX_DIR
  # ------------------------------
  pushd "$SRC_DIR"
  curl -L -O --insecure http://shoup.net/ntl/ntl-"$NTL_VER".tar.gz
  tar xfz ntl-"$NTL_VER".tar.gz
  pushd ntl-$NTL_VER/src
  ./configure NTL_GMP_LIP=on DEF_PREFIX="$PREFIX_DIR" GMP_PREFIX="$PREFIX_DIR" TUNE=x86 SHARED=on
  make -j"$NPROCS"
  make install
  popd
fi

if [[ "$SKIP_NATIVE_BUILD" == 0 ]]; then
  # --------------------------------------
  # Build Barvinok (and ISL) into the prefix
  # --------------------------------------
  pushd "$SRC_DIR"
  rm -rf barvinok || true
  git clone https://github.com/inducer/barvinok.git
  pushd barvinok
  git checkout "$BARVINOK_GIT_REV"
  ensure_autotools
  numtries=1
  while ! ./get_submodules.sh; do
    sleep 5
    numtries=$((numtries+1))
    if [[ "$numtries" == 5 ]]; then
      echo "*** getting barvinok submodules failed even after a few tries"
      exit 1
    fi
  done
  sh autogen.sh
  ./configure \
    --prefix="$PREFIX_DIR" \
    --with-ntl-prefix="$PREFIX_DIR" \
    --with-gmp-prefix="$PREFIX_DIR" \
    --enable-shared-barvinok \
    --with-pet=no

  BARVINOK_ADDITIONAL_MAKE_ARGS=""
  if [[ "$(uname)" == "Darwin" ]]; then
    BARVINOK_ADDITIONAL_MAKE_ARGS=CFLAGS="-Wno-error=implicit-function-declaration"
  fi
  make $BARVINOK_ADDITIONAL_MAKE_ARGS -j"$NPROCS"
  make install
  popd
fi

# --------------------------------------
# Build islpy with Barvinok, rename package
# --------------------------------------
pushd "$SRC_DIR"
"$PYTHON_BIN" -m pip install --upgrade pip || true
# Download the islpy sdist directly from PyPI JSON to avoid invoking any build backend.
python - <<'PY'
import json, os, sys, urllib.request
ver = (os.environ.get("ISLPY_BASE_VERSION") or os.environ.get("ISLPY_VERSION", "")).strip()
if not ver:
    print("Missing ISLPY_VERSION", file=sys.stderr)
    sys.exit(1)
api_url = f"https://pypi.org/pypi/islpy/{ver}/json"
with urllib.request.urlopen(api_url) as resp:
    data = json.load(resp)
sdist = next((u for u in data.get("urls", []) if u.get("packagetype") == "sdist"), None)
if not sdist:
    print("No sdist found for islpy==" + ver, file=sys.stderr)
    sys.exit(1)
url = sdist["url"]
filename = sdist["filename"]
print(f"Downloading {url} -> {filename}")
urllib.request.urlretrieve(url, filename)
PY
SDIST=$(ls islpy-*.tar.gz)
if [[ -z "$SDIST" || ! -f "$SDIST" ]]; then
  echo "Failed to download islpy sdist" >&2
  exit 1
fi
rm -rf islpy-*/ || true
tar xfz "$SDIST"
PKGDIR=$(echo islpy-*/)
pushd "$PKGDIR"

# Ensure GPL-2 LICENSE is present in the upstream source so wheels include it
cp -f "$ROOT_DIR/LICENSE" "$PWD/LICENSE"

# Discover site-packages path for the active interpreter
SITE_PACKAGES=$("$PYTHON_BIN" - <<'PY'
import sysconfig
print(sysconfig.get_paths()["purelib"])
PY
)

# Patch project name in pyproject.toml (islpy -> islpy-barvinok)
python - "$PWD/pyproject.toml" <<'PY'
import sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
txt = txt.replace('name = "islpy"', 'name = "islpy-barvinok"')
open(pth, 'w', encoding='utf-8').write(txt)
print('Patched project name to islpy-barvinok')
PY

# Patch license metadata and classifier to GPL-2 and ensure License file is referenced
python - "$PWD/pyproject.toml" <<'PY'
import re, sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()

# Ensure license field points to bundled LICENSE
if re.search(r'^license\s*=\s*', txt, flags=re.M):
    txt = re.sub(r'^license\s*=.*$', 'license = { file = "LICENSE" }', txt, flags=re.M)
else:
    # Insert under [project] header
    txt = re.sub(r'^(\[project\].*?)$', r"\\1\nlicense = { file = \"LICENSE\" }", txt, flags=re.S)

# Replace MIT classifier with GPLv2; add if none present
if 'License :: OSI Approved :: GNU General Public License v2 (GPLv2)' not in txt:
    if re.search(r'^\s*"License :: OSI Approved :: MIT License"\s*,?\s*$', txt, flags=re.M):
        txt = re.sub(r'^\s*"License :: OSI Approved :: MIT License"\s*,?\s*$',
                     '  "License :: OSI Approved :: GNU General Public License v2 (GPLv2)",',
                     txt, flags=re.M)
    else:
        # Try to append to classifiers array if present
        m = re.search(r"(\nclassifiers\s*=\s*\[)([\s\S]*?)(\])", txt)
        if m:
            start, body, end = m.groups()
            if 'GNU General Public License v2' not in body:
                body = body.rstrip() + "\n  \"License :: OSI Approved :: GNU General Public License v2 (GPLv2)\",\n"
                txt = txt[:m.start()] + start + body + end + txt[m.end():]

open(pth, 'w', encoding='utf-8').write(txt)
print('Updated license metadata to GPL-2 and ensured LICENSE is included')
PY

# Ensure build-backend can be imported by adding backend-path to [build-system]
python - "$PWD/pyproject.toml" <<'PY'
import os, sys
pth = sys.argv[1]
site_pkgs = os.environ.get("SITE_PACKAGES", "")
txt = open(pth, 'r', encoding='utf-8').read()
if "[build-system]" in txt and site_pkgs:
    head, rest = txt.split("[build-system]", 1)
    sect_end = rest.find("\n[")
    if sect_end == -1:
        body, tail = rest, ""
    else:
        body, tail = rest[:sect_end], rest[sect_end:]
    if "backend-path" not in body:
        body = body.rstrip() + f"\nbackend-path = [\"{site_pkgs}\"]\n"
        new_txt = head + "[build-system]" + body + tail
        open(pth, 'w', encoding='utf-8').write(new_txt)
        print('Inserted backend-path pointing to site-packages for backend import')
    else:
        print('backend-path already present; leaving as-is')
else:
    print('No [build-system] section found or SITE_PACKAGES empty; skipping backend-path injection')
PY

# Keep package import name as 'islpy' (no renaming, no import rewrites)

# Ensure wheel includes pure-Python package files (e.g., islpy/__init__.py)
python - "$PWD/pyproject.toml" <<'PY'
import sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
if "[tool.scikit-build]" in txt:
    # add wheel.packages if missing inside the section
    parts = txt.split("[tool.scikit-build]")
    head, rest = parts[0], "[tool.scikit-build]".join(parts[1:])
    sect_end = rest.find("\n[", 1)
    if sect_end == -1:
        body, tail = rest, ""
    else:
        body, tail = rest[:sect_end], rest[sect_end:]
    if "wheel.packages" not in body:
        body = body.rstrip() + "\nwheel.packages = [\"islpy\"]\n"
    txt2 = head + "[tool.scikit-build]" + body + tail
else:
    txt2 = txt.rstrip() + "\n\n[tool.scikit-build]\nwheel.packages = [\"islpy\"]\n"
if txt2 != txt:
    open(pth, 'w', encoding='utf-8').write(txt2)
    print('Ensured tool.scikit-build.wheel.packages = ["islpy"]')
PY

# Loosen Python requirement to support building across 3.10–3.13
python - "$PWD/pyproject.toml" <<'PY'
import re, sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
txt2 = re.sub(r"^requires-python\s*=\s*\"[^\"]*\"", "requires-python = \">=3.10,<3.14\"", txt, flags=re.M)
if txt2 != txt:
    open(pth, 'w', encoding='utf-8').write(txt2)
    print('Relaxed requires-python to ">=3.10,<3.14"')
else:
    print('requires-python already suitable or not found; leaving as-is')
PY

# Remove any backend-path from islpy's pyproject.toml to avoid outer project interference
python - "$PWD/pyproject.toml" <<'PY'
import re, sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
# Remove backend-path line if present
txt2 = re.sub(r"^backend-path\s*=.*$", "", txt, flags=re.M)
if txt2 != txt:
    open(pth, 'w', encoding='utf-8').write(txt2)
    print('Removed backend-path from islpy pyproject.toml')
else:
    print('No backend-path found in islpy pyproject.toml')
PY

# Ensure the linker can find freshly built libs during wheel build
export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$PREFIX_DIR/lib:${DYLD_LIBRARY_PATH:-}"

# Patch islpy/version.py to look up distribution metadata under either
# the original name ("islpy") or the renamed distribution ("islpy-barvinok").
python - "$PWD/islpy/version.py" <<'PY'
import sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
needle = 'VERSION_TEXT = metadata.version("islpy")'
replacement = (
    'try:\n'
    '    VERSION_TEXT = metadata.version("islpy")\n'
    'except metadata.PackageNotFoundError:\n'
    '    VERSION_TEXT = metadata.version("islpy-barvinok")\n'
)
if needle in txt and replacement not in txt:
    txt = txt.replace(needle, replacement)
    open(pth, 'w', encoding='utf-8').write(txt)
    print('Patched islpy/version.py for metadata fallback (islpy → islpy-barvinok).')
else:
    print('islpy/version.py already patched or unexpected format; skipping.')
PY

# Build the wheel with Barvinok enabled
"$PYTHON_BIN" -m pip install --upgrade \
  scikit-build-core nanobind pcpp typing_extensions \
  flit_core hatchling setuptools wheel build cmake ninja || true

# Clear any inherited PYTHONPATH that might interfere with backend discovery
unset PYTHONPATH

# Determine site-packages for the active interpreter to help PEP 517 backend import
SITE_PACKAGES=$("$PYTHON_BIN" - <<'PY'
import sysconfig
print(sysconfig.get_paths()["purelib"])
PY
)

env -i \
  PYTHONNOUSERSITE=1 \
  PATH="$PATH" \
  HOME="${HOME:-/tmp}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
  DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH" \
  ISLPY_VERSION="$ISLPY_BASE_VERSION" \
  BUILD_ROOT="$BUILD_ROOT" \
  PREFIX_DIR="$PREFIX_DIR" \
  PEP517_BACKEND_PATH="$SITE_PACKAGES" \
  "$PYTHON_BIN" -m build \
    --wheel \
    --no-isolation \
    --outdir "$WHEEL_DIR" \
    -Ccmake.define.USE_SHIPPED_ISL=OFF \
    -Ccmake.define.USE_SHIPPED_IMATH=OFF \
    -Ccmake.define.USE_BARVINOK=ON \
    -Ccmake.define.ISL_INC_DIRS:LIST="$PREFIX_DIR/include" \
    -Ccmake.define.ISL_LIB_DIRS:LIST="$PREFIX_DIR/lib"

popd

# --------------------------------------
# Optionally vendor native libs into wheel
# --------------------------------------
if [[ "$(uname)" == "Darwin" ]] && command -v delocate-wheel >/dev/null 2>&1; then
  # Derive deployment target from wheel tag if possible (e.g. macosx_14_0_arm64)
  WHL=$(ls "$WHEEL_DIR"/*.whl | head -n1 || true)
  if [[ -n "${WHL:-}" && "$WHL" =~ macosx_([0-9]+)_([0-9]+)_ ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}
  fi
  ARCH=$(uname -m)
  # Derive and enforce target macOS version for delocation
  if [[ -n "${WHL:-}" && "$WHL" =~ macosx_([0-9]+)_([0-9]+)_ ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
  # Run delocate before temp dirs are cleaned so deps under $PREFIX_DIR are present
  delocate-wheel \
    --require-archs "$ARCH" \
    --require-target-macos-version "${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
    -w "$REPAIRED_DIR" \
    "$WHEEL_DIR"/*.whl || true
elif [[ "$(uname)" == "Linux" ]] && command -v auditwheel >/dev/null 2>&1; then
  for whl in "$WHEEL_DIR"/*.whl; do
    auditwheel repair "$whl" -w "$REPAIRED_DIR" || true
  done
else
  echo "Skipping wheel repair (neither delocate-wheel nor auditwheel found)."
fi

# --------------------------------------
# If ISLPY_VERSION includes a numeric build suffix (e.g., 2025.2.5-3), append it
# as the wheel build tag (hyphenated) in the wheel filename per PEP 427.
# This does not alter the internal metadata version.
# --------------------------------------
if [[ -n "${ISLPY_VERSION:-}" && "$ISLPY_VERSION" == *-* ]]; then
  build_suffix="${ISLPY_VERSION#*-}"
  if [[ "$build_suffix" =~ ^[0-9]+$ ]]; then
    for d in "$REPAIRED_DIR" "$WHEEL_DIR"; do
      if [[ -d "$d" ]]; then
        for whl in "$d"/*.whl; do
          [[ -e "$whl" ]] || continue
          base=$(basename "$whl")
          dir=$(dirname "$whl")
          # Wheel filename: name-version(-build)?-py-abi-plat.whl
          name_part=${base%%-*}
          rest=${base#*-}
          version_part=${rest%%-*}
          tail=${rest#*-}
          # Skip if version already has a build tag
          if [[ "$version_part" == *-* ]]; then
            continue
          fi
          new_base="${name_part}-${version_part}-${build_suffix}-${tail}"
          if [[ "$new_base" != "$base" ]]; then
            mv -f "$whl" "$dir/$new_base"
          fi
        done
      fi
    done
  fi
fi

echo "Done. Artifacts:"
echo "  Prefix: $PREFIX_DIR"
echo "  Wheels: $WHEEL_DIR"
echo "  Repaired (if any): $REPAIRED_DIR"
