#!/usr/bin/env bash
# Check that the Linux x86_64 wheels run on any x86-64 CPU, not only on CPUs
# like the CI machine that built them (NTL, GMP and isl tune for the build
# host by default, which made earlier wheels die with SIGILL elsewhere).
#
# For every *manylinux*x86_64.whl in <wheel dir>:
#   1. objdump the extension and the bundled libs: no AVX/AVX2/AVX-512 (VEX/EVEX
#      encoded), BMI1/BMI2 or ADX instructions. GMP is exempt: it is a fat build
#      that picks its code at runtime based on CPUID.
#   2. Run scripts/run_upstream_tests.py under qemu emulating Nehalem (no AVX,
#      BMI, ADX) and Core 2 (not even SSE4.2/POPCNT).
#
# Needs python3.X on PATH for every wheel's CPython version, plus objdump,
# unzip and qemu-x86_64 (Debian/Ubuntu: apt install qemu-user).
#
# usage: scripts/check_portability.sh <wheel dir>
set -euo pipefail

wheel_dir=$(realpath "$1")
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# AT&T syntax as printed by objdump. tzcnt is not in the list: compilers emit
# "rep bsf" for generic x86-64, which objdump shows as tzcnt.
bad_insns='%[yz]mm[0-9]|%k[0-7]\b|\sv[a-z0-9]+\s+[^#]*%xmm[0-9]|\s(mulx|shlx|shrx|sarx|rorx|pdep|pext|adcx|adox|andn|bextr|blsi|blsmsk|blsr|lzcnt)\s'

shopt -s nullglob
wheels=("$wheel_dir"/*manylinux*x86_64.whl)
if [ ${#wheels[@]} -eq 0 ]; then
  echo "No manylinux x86_64 wheels in $wheel_dir" >&2
  exit 1
fi

failed=()
for whl in "${wheels[@]}"; do
  name=$(basename "$whl")
  cp=$(echo "$name" | grep -oE -- '-cp3[0-9]+-' | head -n1 | tr -d -- -)
  py=python3.${cp#cp3}
  echo "::group::$name"
  ok=1

  rm -rf "$work/x" && mkdir -p "$work/x" && unzip -q "$whl" -d "$work/x"
  for lib in "$work"/x/islpy/_isl*.so "$work"/x/islpy_barvinok.libs/*.so*; do
    case $(basename "$lib") in libgmp-*) continue ;; esac
    n=$(objdump -d --no-show-raw-insn "$lib" | grep -cE "$bad_insns" || true)
    echo "$(basename "$lib"): $n non-baseline instructions"
    if [ "$n" -ne 0 ]; then
      objdump -d --no-show-raw-insn "$lib" | grep -E "$bad_insns" | head -n 5 || true
      ok=0
    fi
  done

  venv=$work/venv-$cp
  "$py" -m venv "$venv"
  "$venv/bin/python" -m pip install -q "$whl" pytest
  "$venv/bin/python" "$here/run_upstream_tests.py" --tests-dir "$work/tests-$cp" --fetch-only
  for cpu in Nehalem core2duo; do
    echo "--- qemu -cpu $cpu"
    if ! qemu-x86_64 -cpu "$cpu" "$venv/bin/python" "$here/run_upstream_tests.py" --tests-dir "$work/tests-$cp"; then
      ok=0
    fi
  done

  echo "::endgroup::"
  if [ $ok -eq 1 ]; then
    echo "OK: $name"
  else
    echo "::error::$name is not portable to older x86-64 CPUs (see log above)"
    failed+=("$name")
  fi
done

if [ ${#failed[@]} -ne 0 ]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "All ${#wheels[@]} wheels OK"
