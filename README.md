# islpy-barvinok

Prebuilt wheels and from-source builds of islpy with Barvinok enabled, with native libraries vendored on Linux and macOS.

This project is a wrapper/builder: it fetches the upstream `islpy` sdist at a pinned version,
builds Barvinok/NTL/ISL via a reproducible script, builds `islpy` with `USE_BARVINOK=ON`,
and publishes wheels. It keeps the import name as `islpy` for compatibility, while the
distribution name on PyPI is `islpy-barvinok`.

Supported platforms: Linux x86_64 (manylinux) and macOS 11+ (x86_64 and arm64).

Upstream project: [inducer/islpy](https://github.com/inducer/islpy). This repo tracks upstream
`islpy` releases on PyPI and rebuilds with Barvinok enabled.

## Usage

- Install: `pip install islpy-barvinok`
- Import:

```python
import islpy
islpy.Set("[N] -> {[x, y] : x >= 0 and y >= 0 and x <= N and y <= N}").card()
```

## How the wheels are built (overview)

- Build dependencies into a local prefix (default `build/prefix`):
  - GMP, NTL, ISL, Barvinok (from upstream sources)
- Build islpy against the prefix with:
  - `-D USE_SHIPPED_ISL=OFF -D USE_SHIPPED_IMATH=OFF -D USE_BARVINOK=ON`
  - `-D ISL_INC_DIRS:LIST=<prefix>/include`
  - `-D ISL_LIB_DIRS:LIST=<prefix>/lib`
- Vendor native libs into wheels:
  - Linux: `auditwheel repair`
  - macOS: `delocate-wheel`

## Building from source (PEP 517)

If a prebuilt wheel is unavailable for your platform, `pip` will build from source
using a custom backend that runs `scripts/build_all.sh`. You will need common C/C++
build tools and autotools installed system-wide:

- macOS: `brew install autoconf automake libtool pkg-config cmake ninja`
- Debian/Ubuntu: `sudo apt-get install -y build-essential autoconf automake libtool pkg-config cmake ninja-build`

Then:

```bash
pip install --no-binary=:all: islpy-barvinok
```

The build downloads sources for GMP, NTL, ISL, and Barvinok, builds them into a local
prefix under `build/`, builds islpy against that prefix with Barvinok enabled, and
produces a wheel that `pip` installs. On macOS, native libraries may be vendored using
`delocate` if available.

## Releases and automation

- Upstream tracking: a scheduled workflow checks PyPI for new `islpy` releases and opens a PR bumping the pinned version.
- Tagging: when such a PR is merged into `main`, another workflow tags the repo with `v<version>`.
- Publishing: tags trigger CI to build wheels on Linux and macOS and publish to PyPI via Trusted Publishing (OIDC).

## Development

- Single-script build:
  - `uv run bash scripts/build_all.sh`
  - Wheels in `build/wheelhouse` and `build/wheelhouse-repaired`.
