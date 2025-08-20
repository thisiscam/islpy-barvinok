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
BUILD_ROOT=${BUILD_ROOT:-"$ROOT_DIR/build"}
PREFIX_DIR=${PREFIX_DIR:-"$BUILD_ROOT/prefix"}
SRC_DIR=${SRC_DIR:-"$BUILD_ROOT/src"}
WHEEL_DIR=${WHEEL_DIR:-"$BUILD_ROOT/wheelhouse"}
REPAIRED_DIR=${REPAIRED_DIR:-"$BUILD_ROOT/wheelhouse-repaired"}
ISLPY_VERSION=${ISLPY_VERSION:-2025.2}
GMP_VER=${GMP_VER:-6.3.0}
NTL_VER=${NTL_VER:-10.5.0}
BARVINOK_GIT_REV=${BARVINOK_GIT_REV:-barvinok-0.41.8}
NPROCS=${NPROCS:-$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}

mkdir -p "$BUILD_ROOT" "$PREFIX_DIR" "$SRC_DIR" "$WHEEL_DIR" "$REPAIRED_DIR"
export ISLPY_VERSION

echo "Using BUILD_ROOT=$BUILD_ROOT"
echo "Using PREFIX_DIR=$PREFIX_DIR"

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

# --------------------------------------
# Build islpy with Barvinok, rename package
# --------------------------------------
pushd "$SRC_DIR"
"$PYTHON_BIN" -m pip install --upgrade pip || true
# Download the islpy sdist directly from PyPI JSON to avoid invoking any build backend.
python - <<'PY'
import json, os, sys, urllib.request
ver = os.environ.get("ISLPY_VERSION", "").strip()
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

# Patch project name in pyproject.toml (islpy -> islpy-barvinok)
python - "$PWD/pyproject.toml" <<'PY'
import sys
pth = sys.argv[1]
txt = open(pth, 'r', encoding='utf-8').read()
txt = txt.replace('name = "islpy"', 'name = "islpy-barvinok"')
open(pth, 'w', encoding='utf-8').write(txt)
print('Patched project name to islpy-barvinok')
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
"$PYTHON_BIN" -m pip wheel . -w "$WHEEL_DIR" \
  --no-build-isolation \
  --config-settings=cmake.define.USE_SHIPPED_ISL=OFF \
  --config-settings=cmake.define.USE_SHIPPED_IMATH=OFF \
  --config-settings=cmake.define.USE_BARVINOK=ON \
  --config-settings=cmake.define.ISL_INC_DIRS:LIST="$PREFIX_DIR/include" \
  --config-settings=cmake.define.ISL_LIB_DIRS:LIST="$PREFIX_DIR/lib"

popd

# --------------------------------------
# Optionally vendor native libs into wheel
# --------------------------------------
if command -v delocate-wheel >/dev/null 2>&1; then
  delocate-wheel -w "$REPAIRED_DIR" "$WHEEL_DIR"/*.whl || true
elif command -v auditwheel >/dev/null 2>&1; then
  for whl in "$WHEEL_DIR"/*.whl; do
    auditwheel repair "$whl" -w "$REPAIRED_DIR" || true
  done
else
  echo "Skipping wheel repair (neither delocate-wheel nor auditwheel found)."
fi

echo "Done. Artifacts:"
echo "  Prefix: $PREFIX_DIR"
echo "  Wheels: $WHEEL_DIR"
echo "  Repaired (if any): $REPAIRED_DIR"
