"""Test an installed islpy-barvinok wheel (cibuildwheel test-command).

1. Smoke test that Barvinok is actually linked in: card() of a parametric set
   only works with Barvinok.
2. Upstream islpy's own test suite, taken from the islpy sdist on PyPI that
   matches the installed version.

pytest runs in this process (not a subprocess) so that the whole run stays
under qemu when scripts/check_portability.sh emulates an older CPU.

usage: run_upstream_tests.py [--tests-dir DIR] [--fetch-only]
  --tests-dir DIR  where to put/reuse the upstream test files (default: temp dir)
  --fetch-only     only download the test files into --tests-dir
"""

from __future__ import annotations

import argparse
import faulthandler
import json
import re
import sys
import tarfile
import tempfile
import urllib.request
from importlib.metadata import version
from pathlib import Path


def upstream_version() -> str:
    # islpy-barvinok X.Y.Z.postN is built from islpy X.Y.Z
    return re.sub(r"\.post\d+$", "", version("islpy-barvinok"))


def fetch_tests(dest: Path, islpy_version: str) -> None:
    api_url = f"https://pypi.org/pypi/islpy/{islpy_version}/json"
    with urllib.request.urlopen(api_url) as resp:
        data = json.load(resp)
    sdist = next((u for u in data.get("urls", []) if u.get("packagetype") == "sdist"), None)
    if not sdist:
        raise SystemExit("No sdist found for islpy==" + islpy_version)
    print(f"Downloading {sdist['url']}", flush=True)
    with tempfile.TemporaryDirectory() as tmp:
        tarball = Path(tmp) / sdist["filename"]
        urllib.request.urlretrieve(sdist["url"], tarball)
        with tarfile.open(tarball) as tf:
            members = [m for m in tf.getmembers()
                       if m.isfile() and re.fullmatch(r"[^/]+/test/[^/]+\.py", m.name)]
            if not members:
                raise SystemExit(f"No test/*.py in {sdist['filename']}")
            dest.mkdir(parents=True, exist_ok=True)
            for m in members:
                f = tf.extractfile(m)
                assert f is not None
                (dest / Path(m.name).name).write_bytes(f.read())


def smoke_test() -> None:
    import islpy as isl

    card = str(isl.Set("[N] -> {[x, y] : 0 <= x <= N and 0 <= y <= N}").card())
    print(sys.version, card, flush=True)
    if "N^2" not in card:
        raise SystemExit(f"card() looks wrong, is Barvinok linked in? got: {card}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests-dir", type=Path)
    parser.add_argument("--fetch-only", action="store_true")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = args.tests_dir or Path(tmp) / "tests"
        if not list(tests_dir.glob("test_*.py")):
            fetch_tests(tests_dir, upstream_version())
        if args.fetch_only:
            return 0

        faulthandler.enable()
        smoke_test()

        import pytest

        return int(pytest.main(["-q", "-p", "no:cacheprovider", "--rootdir", str(tests_dir),
                                str(tests_dir)]))


if __name__ == "__main__":
    sys.exit(main())
