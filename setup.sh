#!/usr/bin/env bash
# One-time setup on macOS (Apple Silicon). Idempotent: safe to re-run.
#   ./setup.sh           installs brew packages, Python env, builds OpenMVS into tools/openmvs-install
#   ./setup.sh --apps    additionally installs CloudCompare + MeshLab (GUI apps, via brew cask)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
log() { printf '\n==> %s\n' "$*"; }

log "Homebrew packages (COLMAP, ffmpeg, OpenMVS build deps)"
brew install colmap ffmpeg cmake boost eigen opencv@4 cgal libomp nanoflann   # opencv@4: OpenMVS 2.3 does not compile against OpenCV 5

if [ "${1:-}" = "--apps" ]; then
  log "GUI apps"
  brew install --cask cloudcompare meshlab
fi

log "Python environment (.venv via uv)"
command -v uv >/dev/null || brew install uv
[ -d .venv ] || uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e .            # pyproject.toml: numpy, opencv, open3d, pycolmap, ezdxf, shapely, ...
uv pip install --python .venv/bin/python -e ".[identify]"  # optional: torch + transformers for scripts/12_identify.py (about 3 GB)

log "OpenMVS (CPU build; provides the dense/mesh/texture stage COLMAP cannot do without CUDA)"
mkdir -p tools
if [ ! -x tools/openmvs-install/bin/OpenMVS/DensifyPointCloud ]; then
  [ -d tools/vcglib ]  || git clone --depth 1 https://github.com/cdcseacave/VCG.git tools/vcglib
  # pinned to the v2.3.0 release: master has moved to vcpkg-only deps that Homebrew does not provide
  [ -d tools/openMVS ] || git clone --depth 1 --branch v2.3.0 https://github.com/cdcseacave/openMVS.git tools/openMVS
  # C++20 removed shared_ptr::unique(); OpenMVS 2.3.0 still uses it
  sed -i '' 's/!store_.unique()/store_.use_count() != 1/' tools/openMVS/libs/Common/FastDelegateCPP11.h
  # SaveOBJ dereferences an empty per-face texture-index array when there is a single texture atlas (segfault on OBJ export)
  sed -i '' 's/const auto texIdx = faceTexindices\[idxFace\];/const auto texIdx = faceTexindices.empty() ? 0 : faceTexindices[idxFace];/' tools/openMVS/libs/MVS/Mesh.cpp
  # Homebrew ships Eigen 5, whose version macros OpenMVS 2.3.0's finder cannot read; Eigen is header-only so vendor 3.4.0
  [ -d tools/eigen-3.4.0 ] || (cd tools && curl -sL https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz | tar xz)
  mkdir -p tools/openMVS/build_mac && cd tools/openMVS/build_mac   # not build/: that dir holds OpenMVS's own cmake helpers
  cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX="$ROOT/tools/openmvs-install" \
    -DVCG_ROOT="$ROOT/tools/vcglib" -DEIGEN3_INCLUDE_DIR="$ROOT/tools/eigen-3.4.0" \
    -DOpenCV_DIR="$(brew --prefix opencv@4)/lib/cmake/opencv4" \
    -DOpenMVS_USE_CUDA=OFF -DOpenMVS_USE_OPENGL=OFF -DOpenMVS_USE_BREAKPAD=OFF \
    -DOpenMVS_USE_CERES=OFF -DOpenMVS_ENABLE_TESTS=OFF -DOpenMVS_USE_OPENMP=ON \
    -DOpenMP_ROOT="$(brew --prefix libomp)" \
    -DCMAKE_CXX_FLAGS="-I$(brew --prefix libomp)/include -Wno-missing-template-arg-list-after-template-kw" -DCMAKE_C_FLAGS="-I$(brew --prefix libomp)/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$(brew --prefix libomp)/lib" -DCMAKE_SHARED_LINKER_FLAGS="-L$(brew --prefix libomp)/lib" \
    -DCMAKE_PREFIX_PATH="$(brew --prefix)"
  make -j"$(sysctl -n hw.ncpu)"
  make install
  cd "$ROOT"
fi
ls tools/openmvs-install/bin/OpenMVS

log "done"
echo "Blender: install from blender.org (or: brew install --cask blender). The Makefile expects /Applications/Blender.app"
