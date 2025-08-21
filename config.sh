# Centralized build configuration for islpy-barvinok
# Bump these to rebuild cached native deps and select upstream islpy version.

# ISLPY_VERSION is resolved from [project].version in pyproject.toml by scripts/build_all.sh

export GMP_VER=${GMP_VER:-6.3.0}
export NTL_VER=${NTL_VER:-10.5.0}
export BARVINOK_GIT_REV=${BARVINOK_GIT_REV:-barvinok-0.41.8}

# macOS minimum deployment target used for delocation and wheel tagging hints
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}


