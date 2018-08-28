#!/bin/bash
# In Docker containers and for some installations, stub libraries are installed.
# The CUDA libraries are installed with the driver but to allow compilation on
# system without the correct drivers stub libraries are installed when the CUDA
# toolkit is installed. The stub libraries allow you to compile the code but not
# to run it because the symbol are missing. The idea is that at run time, we will
# pick the correct libraries instead of the stub ones. This doesn't work when
# using an `rpath` (see https://github.com/NVIDIA/nvidia-docker/issues/775). For
# some reason the problem only appears with CUSolver having missing symbol to
# OpenMP. Removing the stubs fixes the problem.
rm -r  /usr/local/cuda/lib64/stubs
cd $1
rm -rf build
export LD_LIBRARY_PATH=/usr/lib/gcc/x86_64-linux-gnu/5.4.0:${LD_LIBRARY_PATH}
mkdir build && cd build
ARGS=(
  -D CMAKE_BUILD_TYPE=Debug
  -D MFMG_ENABLE_TESTS=ON
  -D MFMG_ENABLE_CUDA=ON
  -D CMAKE_CUDA_FLAGS="-arch=sm_35"
  -D MFMG_ENABLE_CLANGFORMAT=ON
  -D MFMG_ENABLE_COVERAGE=ON
  -D MFMG_ENABLE_DOCUMENTATION=OFF
  -D DEAL_II_DIR=${DEAL_II_DIR}
  -D MFMG_ENABLE_AMGX=ON
  -D AMGX_DIR=${AMGX_DIR}
  -D CMAKE_CXX_FLAGS="-Wall -Wpedantic -Wextra -Wshadow"
  )
cmake "${ARGS[@]}" ../
make -j12
# Because Arpack is not thread-safe we cannot use multithreading
export DEAL_II_NUM_THREADS=1
ctest -j12 --no-compress-output -T Test

# Code coverage
make coverage
curl -s https://codecov.io/bash -o codecov_bash_uploader
chmod +x codecov_bash_uploader
./codecov_bash_uploader -Z -X gcov -f lcov.info

exit 0
