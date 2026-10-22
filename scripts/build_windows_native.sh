#!/usr/bin/env bash
set -euo pipefail
set -x

# Windows (x86_64) native dependency builder. Run inside an MSYS2 UCRT64 shell.
#
# Builds NTL and Barvinok (with its bundled isl and polylib) as static
# libraries with MinGW-w64 GCC against the UCRT, then links them together with
# GMP and the GCC runtime into a single self-contained DLL:
#
#   $PREFIX_DIR/bin/barvinok_bundle.dll      (only depends on system DLLs)
#   $PREFIX_DIR/lib/barvinok_bundle.def      (exports, for an MSVC import lib)
#   $PREFIX_DIR/lib/libbarvinok_bundle.dll.a (MinGW import lib)
#   $PREFIX_DIR/include/{isl,barvinok,polylib,NTL}
#
# Only isl/barvinok C APIs cross the DLL boundary, so the islpy extension
# itself is then built with MSVC (see scripts/build_windows.py). Both sides use
# ucrtbase.dll, so strings malloc'd by isl can be free'd by the extension.

if [[ "${MSYSTEM:-}" != "UCRT64" ]]; then
  echo "ERROR: run this script from an MSYS2 UCRT64 shell (MSYSTEM=${MSYSTEM:-unset})" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/config.sh"

# Use mixed (C:/...) paths: understood by both MSYS tools and native compilers
BUILD_ROOT=$(cygpath -m "${BUILD_ROOT:-$ROOT_DIR/build}")
PREFIX_DIR=$(cygpath -m "${PREFIX_DIR:-$BUILD_ROOT/prefix}")
SRC_DIR=$(cygpath -m "${SRC_DIR:-$BUILD_ROOT/src}")
NPROCS=${NPROCS:-$(nproc)}
# GMP comes from MSYS2 (6.3.0, static archive built with --enable-fat, so it
# runs on any x86_64 CPU rather than only on the CI machine's).
GMP_PREFIX=$(cygpath -m "$MINGW_PREFIX")

mkdir -p "$PREFIX_DIR/bin" "$PREFIX_DIR/lib" "$PREFIX_DIR/include" "$SRC_DIR"

pacman -Q mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gmp || true
test -f "$GMP_PREFIX/lib/libgmp.a"

# Match the language modes of the Linux build (GCC 14) instead of newer
# compiler defaults (C23 / C++20), which old NTL/polylib code is not written for.
export CFLAGS="-O2 -std=gnu17 -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion"
export CXXFLAGS="-O2 -std=gnu++17"

# ------------------------------
# NTL (static)
# ------------------------------
pushd "$SRC_DIR"
rm -rf "ntl-$NTL_VER"
if [[ ! -f "ntl-$NTL_VER.tar.gz" ]]; then
  curl -fL -o "ntl-$NTL_VER.tar.gz" "https://libntl.org/ntl-$NTL_VER.tar.gz" \
    || curl -fL --insecure -o "ntl-$NTL_VER.tar.gz" "http://shoup.net/ntl/ntl-$NTL_VER.tar.gz"
fi
tar xzf "ntl-$NTL_VER.tar.gz"
pushd "ntl-$NTL_VER/src"
# NATIVE=off: no -march=native, the DLL must run on any x86_64 machine
./configure DEF_PREFIX="$PREFIX_DIR" GMP_PREFIX="$GMP_PREFIX" NTL_GMP_LIP=on \
  TUNE=x86 NATIVE=off SHARED=off NTL_THREADS=off \
  CXX=g++ CXXFLAGS="$CXXFLAGS"
make -j"$NPROCS"
make install
popd
popd

# --------------------------------------
# Barvinok + bundled isl and polylib (static)
# --------------------------------------
pushd "$SRC_DIR"
rm -rf "barvinok-$BARVINOK_VER"
curl -fL --retry 5 -O "https://barvinok.sourceforge.io/barvinok-$BARVINOK_VER.tar.gz"
echo "$BARVINOK_SHA256  barvinok-$BARVINOK_VER.tar.gz" | sha256sum -c -
tar xzf "barvinok-$BARVINOK_VER.tar.gz"
pushd "barvinok-$BARVINOK_VER"
shopt -s nullglob
for p in "$ROOT_DIR"/patches/windows/*.patch; do
  patch -p1 < "$p"
done
shopt -u nullglob
./configure \
  --prefix="$PREFIX_DIR" \
  --with-ntl-prefix="$PREFIX_DIR" \
  --with-gmp-prefix="$GMP_PREFIX" \
  --with-pet=no \
  --disable-shared \
  --enable-static

# Only the libraries are needed (the command line tools use POSIX-only APIs).
# isl's BUILT_SOURCES are not made by a library-only target, so make them first.
make -C isl gitversion.h
make -j"$NPROCS" libbarvinok.la

make -C isl install-pkgincludeHEADERS install-nodist_pkgincludeHEADERS
make -C polylib/include install
make install-pkgincludeHEADERS install-nodist_pkgincludeHEADERS

# --------------------------------------
# Link everything into barvinok_bundle.dll
# --------------------------------------
STATIC_LIBS=(.libs/libbarvinok.a isl/.libs/libisl.a polylib/.libs/libpolylibgmp.a)
ls -l "${STATIC_LIBS[@]}"
g++ -shared -o "$PREFIX_DIR/bin/barvinok_bundle.dll" \
  -Wl,--whole-archive "${STATIC_LIBS[@]}" -Wl,--no-whole-archive \
  "$PREFIX_DIR/lib/libntl.a" "$GMP_PREFIX/lib/libgmp.a" \
  -static -static-libgcc -static-libstdc++ \
  -Wl,--export-all-symbols \
  -Wl,--exclude-libs,libntl.a:libgmp.a \
  -Wl,--output-def,"$PREFIX_DIR/lib/barvinok_bundle.def" \
  -Wl,--out-implib,"$PREFIX_DIR/lib/libbarvinok_bundle.dll.a"
popd
popd

# The DLL must be self-contained: no MinGW runtime DLLs and no msvcrt.dll
objdump -p "$PREFIX_DIR/bin/barvinok_bundle.dll" | grep -i "DLL Name" | tee "$BUILD_ROOT/barvinok_bundle-deps.txt"
if grep -Eiq "libgcc|libstdc|libwinpthread|libgmp|msvcrt\.dll" "$BUILD_ROOT/barvinok_bundle-deps.txt"; then
  echo "ERROR: barvinok_bundle.dll depends on non-system DLLs" >&2
  exit 1
fi
grep -c . "$PREFIX_DIR/lib/barvinok_bundle.def"
grep -Eq "^\s+isl_set_card\b" "$PREFIX_DIR/lib/barvinok_bundle.def"
grep -Eq "^\s+isl_ctx_alloc\b" "$PREFIX_DIR/lib/barvinok_bundle.def"

# --------------------------------------
# Smoke test the DLL from C (independent of Python/MSVC)
# --------------------------------------
SMOKE_DIR="$BUILD_ROOT/native-smoke"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"
cat > "$SMOKE_DIR/smoke.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <isl/ctx.h>
#include <isl/set.h>
#include <isl/polynomial.h>
#include <barvinok/isl.h>

int main(void)
{
	isl_ctx *ctx = isl_ctx_alloc();
	isl_set *set = isl_set_read_from_str(ctx,
		"[N] -> { [x, y] : 0 <= x <= N and 0 <= y <= N }");
	isl_pw_qpolynomial *card = isl_set_card(set);
	char *str = isl_pw_qpolynomial_to_str(card);
	printf("%s\n", str);
	free(str);
	isl_pw_qpolynomial_free(card);
	isl_ctx_free(ctx);
	return 0;
}
EOF
gcc -O1 -I"$PREFIX_DIR/include" -o "$SMOKE_DIR/smoke.exe" "$SMOKE_DIR/smoke.c" \
  -L"$PREFIX_DIR/lib" -lbarvinok_bundle
cp "$PREFIX_DIR/bin/barvinok_bundle.dll" "$SMOKE_DIR/"
"$SMOKE_DIR/smoke.exe" | tee "$SMOKE_DIR/out.txt"
grep -q "N" "$SMOKE_DIR/out.txt"

echo "Done. Native prefix: $PREFIX_DIR"
