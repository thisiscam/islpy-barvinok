# islpy-barvinok

Binary wheels of islpy built with Barvinok, with native libraries vendored for Linux and macOS.

This project is a wrapper/builder: it fetches upstream islpy sdist at a pinned version,
builds Barvinok/NTL/ISL via a reproducible script, builds islpy with USE_BARVINOK=ON,
renames the import to `islpy_barvinok` to avoid conflicts, and publishes wheels.

Source builds are not supported; use the prebuilt wheels. Windows is not supported.

## Usage

- Install: `pip install islpy-barvinok`
- Import: `import islpy_barvinok as isl`

## How the wheels are built (overview)

- Build dependencies into a local prefix (default `islpy_barvinok/build/prefix`):
  - GMP, NTL, ISL, Barvinok (from upstream sources)
- Build islpy against the prefix with:
  - `-D USE_SHIPPED_ISL=OFF -D USE_SHIPPED_IMATH=OFF -D USE_BARVINOK=ON`
  - `-D ISL_INC_DIRS:LIST=<prefix>/include`
  - `-D ISL_LIB_DIRS:LIST=<prefix>/lib`
- Vendor native libs into wheels:
  - Linux: `auditwheel repair`
  - macOS: `delocate-wheel`

## Development

- Single-script build:
  - `uv run bash scripts/build_all.sh`
  - Wheels in `islpy_barvinok/build/wheelhouse` and `islpy_barvinok/build/wheelhouse-repaired`.
