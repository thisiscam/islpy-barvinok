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
        # Prefer repaired wheels (wheelhouse-repaired) over raw wheels
        repaired_wheels = [
            w
            for w in wheels
            if os.path.basename(os.path.dirname(w)).endswith("wheelhouse-repaired")
        ]
        chosen: str | None = None
        search_order = [repaired_wheels, wheels]
        for seq in search_order:
            for whl in reversed(seq):
                base = os.path.basename(whl)
                if base.startswith("islpy_barvinok-") or base.startswith(
                    "islpy-barvinok-"
                ):
                    chosen = whl
                    break
            if chosen:
                break
        if chosen is None:
            chosen = repaired_wheels[-1] if repaired_wheels else wheels[-1]
        target = os.path.join(wheel_directory, os.path.basename(chosen))
        os.makedirs(wheel_directory, exist_ok=True)
        shutil.copy2(chosen, target)
        return os.path.basename(target)


def build_sdist(sdist_directory, config_settings=None):  # noqa: N802
    os.makedirs(sdist_directory, exist_ok=True)
    # Create an sdist that includes PKG-INFO as required by PyPI/twine
    root = _project_root()
    meta = _read_project_core_metadata(root)
    base_name = f"{meta['name']}-{meta['version']}"
    sdist_name = base_name + ".tar.gz"
    sdist_path = os.path.join(sdist_directory, sdist_name)

    include_paths = [
        "pyproject.toml",
        "README.md",
        "LICENSE",
        "build_backend.py",
        "config.sh",
        os.path.join("scripts", "build_all.sh"),
    ]

    # Best-effort long description from README.md
    long_description = ""
    readme_path = os.path.join(root, "README.md")
    if os.path.exists(readme_path):
        try:
            with open(readme_path, "r", encoding="utf-8") as f:
                long_description = f.read()
        except OSError:
            long_description = ""

    # Compose PKG-INFO content per Core Metadata 2.1
    pkg_info_lines: list[str] = []
    pkg_info_lines.append("Metadata-Version: 2.1")
    pkg_info_lines.append(f"Name: {meta['name']}")
    pkg_info_lines.append(f"Version: {meta['version']}")
    if meta.get("summary"):
        pkg_info_lines.append(f"Summary: {meta['summary']}")
    if meta.get("home_page"):
        pkg_info_lines.append(f"Home-page: {meta['home_page']}")
    if meta.get("author"):
        pkg_info_lines.append(f"Author: {meta['author']}")
    if meta.get("requires_python"):
        pkg_info_lines.append(f"Requires-Python: {meta['requires_python']}")
    # Point to included license file
    pkg_info_lines.append("License-File: LICENSE")
    for classifier in meta.get("classifiers", []):
        pkg_info_lines.append(f"Classifier: {classifier}")
    for url_name, url in meta.get("project_urls", {}).items():
        pkg_info_lines.append(f"Project-URL: {url_name}, {url}")
    # Long description
    if long_description:
        pkg_info_lines.append("Description-Content-Type: text/markdown")
        pkg_info_lines.append("")
        pkg_info_lines.append(long_description)

    pkg_info_content = "\n".join(pkg_info_lines) + "\n"

    with tarfile.open(sdist_path, "w:gz") as tf:
        # Add project files
        for rel in include_paths:
            src = os.path.join(root, rel)
            if not os.path.exists(src):
                continue
            tf.add(src, arcname=os.path.join(base_name, rel))
        # Add PKG-INFO at the root of the archive
        pkg_info_tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
        try:
            pkg_info_tmp.write(pkg_info_content)
            pkg_info_tmp.flush()
            pkg_info_tmp.close()
            tf.add(pkg_info_tmp.name, arcname=os.path.join(base_name, "PKG-INFO"))
        finally:
            try:
                os.unlink(pkg_info_tmp.name)
            except OSError:
                pass

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


def _read_project_core_metadata(root_dir: str) -> dict:
    """Best-effort extraction of core metadata from pyproject.toml.

    Avoid heavy dependencies. Prefer tomllib if available, else fall back to
    simple line-based parsing for the fields we need.
    """
    pyproject_path = os.path.join(root_dir, "pyproject.toml")
    data: dict = {}
    try:
        import tomllib  # Python 3.11+

        with open(pyproject_path, "rb") as f:
            data = tomllib.load(f)
    except Exception:
        # Fall back to minimal parsing
        data = {}
        try:
            with open(pyproject_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except OSError:
            lines = []
        in_project = False
        project: dict = {}
        for raw in lines:
            line = raw.strip()
            if line == "[project]":
                in_project = True
                continue
            if in_project and line.startswith("[") and "]" in line:
                break
            if in_project and "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                project[key] = val
        data["project"] = project

    project = data.get("project", {})
    name = project.get("name", "islpy-barvinok")
    version = project.get("version", _read_project_version(root_dir))
    # Do not override upstream version for metadata; wheel filename tagging is handled post-build
    summary = project.get("description", "")
    requires_python = project.get("requires-python", "")
    # URLs
    urls = data.get("project", {}).get("urls", {})
    home_page = urls.get("Homepage") or urls.get("Home") or ""
    # Author (first author only)
    author = ""
    authors = project.get("authors", [])
    if isinstance(authors, list) and authors:
        first = authors[0]
        if isinstance(first, dict):
            author = first.get("name") or ""
        elif isinstance(first, str):
            author = first
    classifiers = project.get("classifiers", []) or []

    return {
        "name": name,
        "version": version,
        "summary": summary,
        "home_page": home_page,
        "author": author,
        "requires_python": requires_python,
        "classifiers": classifiers,
        "project_urls": urls if isinstance(urls, dict) else {},
    }
