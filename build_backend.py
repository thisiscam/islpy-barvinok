import glob
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
import sys


def _project_root() -> str:
    return os.path.abspath(os.path.dirname(__file__))


def _run_build_all(temp_build_root: str) -> tuple[str, list[str]]:
    """Run scripts/build_all.sh with BUILD_ROOT set to a temp dir.

    Returns the directory containing produced wheels and the list of wheel paths.
    """
    env = os.environ.copy()
    # Use caller-provided BUILD_ROOT if available (e.g., CI cache path),
    # otherwise default to a temporary directory
    if "BUILD_ROOT" not in env or not env["BUILD_ROOT"].strip():
        env["BUILD_ROOT"] = temp_build_root
    # Ensure the build uses the same Python interpreter/tag cibuildwheel is targeting
    env["PYTHON_BIN"] = sys.executable

    # Clear environment variables that might interfere with inner build backend discovery
    env.pop("PYTHONPATH", None)
    env.pop("PEP517_BUILD_BACKEND", None)

    script_path = os.path.join(_project_root(), "scripts", "build_all.sh")
    if not os.path.exists(script_path):
        raise FileNotFoundError(f"Missing build script: {script_path}")

    subprocess.check_call(["bash", script_path], cwd=_project_root(), env=env)

    # Collect candidate wheel directories from both temp and configured BUILD_ROOT
    build_root = env["BUILD_ROOT"]
    candidate_dirs = [
        os.path.join(temp_build_root, "wheelhouse-repaired"),
        os.path.join(temp_build_root, "wheelhouse"),
        os.path.join(build_root, "wheelhouse-repaired"),
        os.path.join(build_root, "wheelhouse"),
    ]

    wheels: list[str] = []
    chosen_dir: str | None = None
    for cand in candidate_dirs:
        if os.path.isdir(cand):
            found = sorted(glob.glob(os.path.join(cand, "*.whl")))
            if found:
                wheels.extend(found)
                if chosen_dir is None:
                    chosen_dir = cand

    if not wheels or chosen_dir is None:
        raise RuntimeError("Build script did not produce any wheels")

    return (chosen_dir, wheels)


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):  # noqa: N802 (pep517 signature)
    # Build a wheel in a temp area, extract its *.dist-info to metadata_directory
    with tempfile.TemporaryDirectory(prefix="islpy-barvinok-build-") as tmp:
        _, wheels = _run_build_all(tmp)
        wheel_path = wheels[-1]
        with tempfile.TemporaryDirectory(prefix="islpy-barvinok-unzip-") as unzip_dir:
            with zipfile.ZipFile(wheel_path) as zf:
                zf.extractall(unzip_dir)
            dist_infos = [
                name
                for name in os.listdir(unzip_dir)
                if name.endswith(".dist-info")
                and os.path.isdir(os.path.join(unzip_dir, name))
            ]
            if not dist_infos:
                raise RuntimeError("No .dist-info directory found in built wheel")
            dist_info = dist_infos[0]
            src = os.path.join(unzip_dir, dist_info)
            dst = os.path.join(metadata_directory, dist_info)
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            return dist_info


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):  # noqa: N802
    with tempfile.TemporaryDirectory(prefix="islpy-barvinok-build-") as tmp:
        _, wheels = _run_build_all(tmp)
        # Prefer a wheel that matches our distribution name
        chosen = None
        for whl in reversed(wheels):
            base = os.path.basename(whl)
            if base.startswith("islpy_barvinok-") or base.startswith("islpy-barvinok-"):
                chosen = whl
                break
        if chosen is None:
            chosen = wheels[-1]
        target = os.path.join(wheel_directory, os.path.basename(chosen))
        os.makedirs(wheel_directory, exist_ok=True)
        shutil.copy2(chosen, target)
        return os.path.basename(target)


def build_sdist(sdist_directory, config_settings=None):  # noqa: N802
    os.makedirs(sdist_directory, exist_ok=True)
    # Create a minimal sdist with only what's needed to build
    root = _project_root()
    base_name = f"islpy-barvinok-{_read_project_version(root)}"
    sdist_name = base_name + ".tar.gz"
    sdist_path = os.path.join(sdist_directory, sdist_name)

    include_paths = [
        "pyproject.toml",
        "README.md",
        "LICENSE",
        "build_backend.py",
        os.path.join("scripts", "build_all.sh"),
    ]
    with tarfile.open(sdist_path, "w:gz") as tf:
        for rel in include_paths:
            src = os.path.join(root, rel)
            if not os.path.exists(src):
                continue
            tf.add(src, arcname=os.path.join(base_name, rel))
    return os.path.basename(sdist_path)


def _read_project_version(root_dir: str) -> str:
    # Lightweight TOML parse: read the [project] version line
    version = "0.0.0"
    toml_path = os.path.join(root_dir, "pyproject.toml")
    try:
        with open(toml_path, "r", encoding="utf-8") as f:
            in_project = False
            for line in f:
                if line.strip() == "[project]":
                    in_project = True
                    continue
                if in_project and line.strip().startswith("version"):
                    # version = "X"
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        version = parts[1].strip().strip('"').strip("'")
                        break
                if in_project and line.startswith("[") and "]" in line:
                    break
    except OSError:
        pass
    return version
