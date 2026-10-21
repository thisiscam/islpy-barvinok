# Centralized build configuration for islpy-barvinok
# Bump these to rebuild cached native deps and select upstream islpy version.

# ISLPY_VERSION is resolved from [project].version in pyproject.toml by scripts/build_all.sh

export GMP_VER=${GMP_VER:-6.3.0}
export NTL_VER=${NTL_VER:-10.5.0}
# Barvinok release tarball (bundles isl and polylib). The git submodules point
# at repo.or.cz, which is unreachable from some CI regions, so don't use git.
export BARVINOK_VER=${BARVINOK_VER:-0.41.8}
export BARVINOK_SHA256=${BARVINOK_SHA256:-cc40feee5a882ea9fbaee696b303f377e9c46b2321831303480bed1adb8eca3a}

# macOS minimum deployment target used for delocation and wheel tagging hints
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}


