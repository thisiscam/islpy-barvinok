"""Windows counterpart of the islpy part of scripts/build_all.sh.

Expects the native prefix produced by scripts/build_windows_native.sh (run in
an MSYS2 UCRT64 shell): headers in include/, bin/barvinok_bundle.dll and
lib/barvinok_bundle.def. Downloads the upstream islpy sdist, applies the same
metadata patches as build_all.sh, builds it with MSVC linked against
barvinok_bundle.dll and writes the wheel to $BUILD_ROOT/wheelhouse.

Outside of cibuildwheel (which runs delvewheel itself), the wheel is also
repaired with delvewheel into $BUILD_ROOT/wheelhouse-repaired if available.
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
DLL_NAME = "barvinok_bundle"


def run(cmd: list[str], **kwargs) -> None:
    print("+", subprocess.list2cmdline(cmd), flush=True)
    subprocess.check_call(cmd, **kwargs)


def project_version() -> str:
    txt = (ROOT_DIR / "pyproject.toml").read_text(encoding="utf-8")
    m = re.search(r"^version\s*=\s*\"([^\"]+)\"", txt, flags=re.M)
    if not m:
        raise SystemExit("ERROR: Could not determine ISLPY_VERSION from pyproject.toml or env")
    return m.group(1)


def find_lib_exe() -> str | None:
    found = shutil.which("lib")
    if found:
        return found
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = Path(pf86) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    if not vswhere.exists():
        return None
    out = subprocess.run(
        [str(vswhere), "-latest", "-products", "*",
         "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
         "-find", r"VC\Tools\MSVC\**\bin\Hostx64\x64\lib.exe"],
        capture_output=True, text=True, check=False).stdout.splitlines()
    out = [line.strip() for line in out if line.strip()]
    return out[0] if out else None


def ensure_import_lib(prefix: Path) -> None:
    """Create the MSVC import library barvinok_bundle.lib from the .def file."""
    lib_dir = prefix / "lib"
    implib = lib_dir / f"{DLL_NAME}.lib"
    if implib.exists():
        return
    lib_exe = find_lib_exe()
    if lib_exe:
        run([lib_exe, "/nologo", "/machine:x64", f"/name:{DLL_NAME}.dll",
             f"/def:{lib_dir / (DLL_NAME + '.def')}", f"/out:{implib}"])
    else:
        # GNU import libraries are generally usable by link.exe as well
        print("WARNING: lib.exe not found; using the MinGW import library", flush=True)
        shutil.copy2(lib_dir / f"lib{DLL_NAME}.dll.a", implib)


def download_sdist(version: str, dest: Path) -> Path:
    api_url = f"https://pypi.org/pypi/islpy/{version}/json"
    with urllib.request.urlopen(api_url) as resp:
        data = json.load(resp)
    sdist = next((u for u in data.get("urls", []) if u.get("packagetype") == "sdist"), None)
    if not sdist:
        raise SystemExit("No sdist found for islpy==" + version)
    target = dest / sdist["filename"]
    print(f"Downloading {sdist['url']} -> {target}", flush=True)
    urllib.request.urlretrieve(sdist["url"], target)
    return target


def patch_pyproject(pth: Path, target_ver: str) -> None:
    """Same edits as the inline Python snippets in build_all.sh."""
    txt = pth.read_text(encoding="utf-8")

    # islpy -> islpy-barvinok, version
    txt = txt.replace('name = "islpy"', 'name = "islpy-barvinok"')
    txt = re.sub(r'^version\s*=\s*"[^"]*"', f'version = "{target_ver}"', txt, flags=re.M)

    # GPL-2 license file and classifier
    if re.search(r'^license\s*=\s*', txt, flags=re.M):
        txt = re.sub(r'^license\s*=.*$', 'license = { file = "LICENSE" }', txt, flags=re.M)
    else:
        txt = re.sub(r'^(\[project\].*?)$', r"\1\nlicense = { file = \"LICENSE\" }", txt, flags=re.S)
    gpl = "License :: OSI Approved :: GNU General Public License v2 (GPLv2)"
    if gpl not in txt:
        if re.search(r'^\s*"License :: OSI Approved :: MIT License"\s*,?\s*$', txt, flags=re.M):
            txt = re.sub(r'^\s*"License :: OSI Approved :: MIT License"\s*,?\s*$',
                         f'  "{gpl}",', txt, flags=re.M)
        else:
            m = re.search(r"(\nclassifiers\s*=\s*\[)([\s\S]*?)(\])", txt)
            if m:
                start, body, end = m.groups()
                body = body.rstrip() + f"\n  \"{gpl}\",\n"
                txt = txt[:m.start()] + start + body + end + txt[m.end():]

    # Ensure the wheel includes the pure-Python package files
    if "[tool.scikit-build]" in txt:
        head, rest = txt.split("[tool.scikit-build]", 1)
        sect_end = rest.find("\n[", 1)
        body, tail = (rest, "") if sect_end == -1 else (rest[:sect_end], rest[sect_end:])
        if "wheel.packages" not in body:
            body = body.rstrip() + "\nwheel.packages = [\"islpy\"]\n"
        txt = head + "[tool.scikit-build]" + body + tail
    else:
        txt = txt.rstrip() + "\n\n[tool.scikit-build]\nwheel.packages = [\"islpy\"]\n"

    # No upper cap on the Python version
    txt = re.sub(r"^requires-python\s*=\s*\"[^\"]*\"", "requires-python = \">=3.10\"", txt, flags=re.M)
    txt = re.sub(r"^backend-path\s*=.*$", "", txt, flags=re.M)
    pth.write_text(txt, encoding="utf-8")


def patch_version_py(pth: Path) -> None:
    txt = pth.read_text(encoding="utf-8")
    needle = 'VERSION_TEXT = metadata.version("islpy")'
    replacement = (
        'try:\n'
        '    VERSION_TEXT = metadata.version("islpy")\n'
        'except metadata.PackageNotFoundError:\n'
        '    VERSION_TEXT = metadata.version("islpy-barvinok")\n'
        '# Strip .postN suffix so the numeric regex below can parse it as integers\n'
        'VERSION_TEXT = VERSION_TEXT.split(".post")[0]\n'
    )
    if needle in txt and replacement not in txt:
        pth.write_text(txt.replace(needle, replacement), encoding="utf-8")


def patch_for_windows(pkgdir: Path) -> None:
    # Stub generation imports the freshly built _isl. With the (multi-config)
    # Visual Studio generator the module lands in a per-config subdirectory.
    cml = pkgdir / "CMakeLists.txt"
    txt = cml.read_text(encoding="utf-8")
    old = "--python-path ${CMAKE_BINARY_DIR}"
    if old not in txt:
        raise SystemExit("islpy CMakeLists.txt changed: stubgen --python-path not found")
    cml.write_text(txt.replace(old, "--python-path $<TARGET_FILE_DIR:_isl>"), encoding="utf-8")

    # ... and _isl needs barvinok_bundle.dll, which Python only finds in
    # directories registered with os.add_dll_directory().
    stubgen = pkgdir / "stubgen" / "stubgen.py"
    txt = stubgen.read_text(encoding="utf-8")
    old = "import argparse\n"
    if not txt.startswith(old):
        raise SystemExit("islpy stubgen/stubgen.py changed: unexpected first line")
    new = (old + "import os\n"
           "for _dll_dir in os.environ.get(\"ISLPY_DLL_DIRS\", \"\").split(os.pathsep):\n"
           "    if _dll_dir:\n"
           "        os.add_dll_directory(_dll_dir)\n")
    stubgen.write_text(new + txt[len(old):], encoding="utf-8")


def add_build_tag(dirs: list[Path], islpy_version: str) -> None:
    """Append a numeric -N suffix of ISLPY_VERSION as the wheel build tag."""
    if "-" not in islpy_version:
        return
    build_suffix = islpy_version.split("-", 1)[1]
    if not build_suffix.isdigit():
        return
    for d in dirs:
        for whl in d.glob("*.whl"):
            name, rest = whl.name.split("-", 1)
            version, tail = rest.split("-", 1)
            new = whl.with_name(f"{name}-{version}-{build_suffix}-{tail}")
            if new != whl:
                whl.replace(new)


def main() -> None:
    build_root = Path(os.environ.get("BUILD_ROOT") or ROOT_DIR / "build")
    prefix = Path(os.environ.get("PREFIX_DIR") or build_root / "prefix")
    src_dir = Path(os.environ.get("SRC_DIR") or build_root / "src")
    wheel_dir = Path(os.environ.get("WHEEL_DIR") or build_root / "wheelhouse")
    repaired_dir = Path(os.environ.get("REPAIRED_DIR") or build_root / "wheelhouse-repaired")

    islpy_version = os.environ.get("ISLPY_VERSION") or project_version()
    base_version = os.environ.get("ISLPY_BASE_VERSION") or islpy_version.split("-")[0].split(".post")[0]

    dll = prefix / "bin" / f"{DLL_NAME}.dll"
    if not dll.exists():
        raise SystemExit(
            f"ERROR: {dll} not found. Build the native libraries first by running "
            "scripts/build_windows_native.sh in an MSYS2 UCRT64 shell "
            "(with the same BUILD_ROOT/PREFIX_DIR).")
    ensure_import_lib(prefix)

    for d in (src_dir, wheel_dir, repaired_dir):
        d.mkdir(parents=True, exist_ok=True)
    # One build root may be shared by several Python versions: drop old wheels
    for old in [*wheel_dir.glob("*.whl"), *repaired_dir.glob("*.whl")]:
        old.unlink()

    py = sys.executable
    # PEP 517 isolated build environments may come without pip
    if subprocess.run([py, "-m", "pip", "--version"], capture_output=True).returncode != 0:
        run([py, "-m", "ensurepip", "--upgrade"])
    run([py, "-m", "pip", "install", "--upgrade",
         "scikit-build-core", "nanobind", "pcpp", "typing_extensions",
         "build", "cmake", "ninja", "setuptools", "wheel"])

    for old in glob.glob(str(src_dir / "islpy-*")):
        if os.path.isdir(old):
            shutil.rmtree(old)
        else:
            os.unlink(old)
    sdist = download_sdist(base_version, src_dir)
    with tarfile.open(sdist) as tf:
        if hasattr(tarfile, "data_filter"):
            tf.extractall(src_dir, filter="data")
        else:
            tf.extractall(src_dir)
    pkgdir = next(p for p in src_dir.glob("islpy-*") if p.is_dir())

    shutil.copy2(ROOT_DIR / "LICENSE", pkgdir / "LICENSE")
    patch_pyproject(pkgdir / "pyproject.toml", islpy_version)
    patch_version_py(pkgdir / "islpy" / "version.py")
    patch_for_windows(pkgdir)

    # Drop the outer PEP 517 hook settings (backend name/path of *this*
    # project), which would otherwise leak into the inner islpy build.
    env = {k: v for k, v in os.environ.items()
           if k != "PYTHONPATH"
           and not k.startswith(("PEP517_", "_PYPROJECT_HOOKS_"))}
    env["PYTHONNOUSERSITE"] = "1"
    env["PYTHONUTF8"] = "1"
    env["ISLPY_DLL_DIRS"] = str(prefix / "bin")

    inc = (prefix / "include").as_posix()
    lib = (prefix / "lib").as_posix()
    run([py, "-m", "build", "--wheel", "--no-isolation", "--outdir", str(wheel_dir),
         "-Ccmake.define.USE_SHIPPED_ISL=OFF",
         "-Ccmake.define.USE_SHIPPED_IMATH=OFF",
         "-Ccmake.define.USE_BARVINOK=ON",
         f"-Ccmake.define.ISL_INC_DIRS:LIST={inc}",
         f"-Ccmake.define.ISL_LIB_DIRS:LIST={lib}",
         f"-Ccmake.define.ISL_LIB_NAMES={DLL_NAME}",
         ], cwd=pkgdir, env=env)

    if os.environ.get("CIBUILDWHEEL") != "1" and shutil.which("delvewheel"):
        for whl in wheel_dir.glob("*.whl"):
            run(["delvewheel", "repair", "--add-path", str(prefix / "bin"),
                 "-w", str(repaired_dir), str(whl)])
    else:
        print("Skipping wheel repair here (cibuildwheel runs delvewheel, "
              "or delvewheel is not installed).", flush=True)

    add_build_tag([repaired_dir, wheel_dir], islpy_version)

    print("Done. Artifacts:")
    print(f"  Prefix: {prefix}")
    print(f"  Wheels: {wheel_dir}")
    print(f"  Repaired (if any): {repaired_dir}")


if __name__ == "__main__":
    main()
