#!/usr/bin/env bash
# 为 iOS arm64 交叉编译 LLVM libc++/libc++abi 动态库。
# mongod 用 Homebrew LLVM 19 头文件编译，会引用 std::pmr 等符号；设备自带的
# /usr/lib/libc++.1.dylib（尤其 iOS 15）过旧，运行时会 dyld 报错，必须随包带上新版。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_DIR="${IOS_LIBCXX_DIR:-${REPO_ROOT}/.ios-libcxx}"
LLVM_VERSION="${LLVM_RUNTIME_VERSION:-19.1.7}"
BUILD_DIR="${REPO_ROOT}/.ios-libcxx-build"
SRC_DIR="${BUILD_DIR}/llvm-project-${LLVM_VERSION}.src"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="${SDK}"
DEPLOY="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

if [[ -f "${INSTALL_DIR}/lib/libc++.1.dylib" && -f "${INSTALL_DIR}/lib/libc++abi.dylib" ]]; then
  if file -b "${INSTALL_DIR}/lib/libc++.1.dylib" | grep -q 'arm64'; then
    if nm -gU "${INSTALL_DIR}/lib/libc++.1.dylib" 2>/dev/null | grep -q '__ZTVNSt3__13pmr15memory_resourceE'; then
      echo "Reusing iOS libc++: ${INSTALL_DIR}"
      exit 0
    fi
  fi
fi

echo "Building iOS arm64 libc++ ${LLVM_VERSION} (deployment ${DEPLOY})"
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}"

if [[ ! -d "${SRC_DIR}" ]]; then
  TARBALL="${BUILD_DIR}/llvm-project-${LLVM_VERSION}.src.tar.xz"
  URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
  echo "Downloading ${URL}"
  curl -fsSL --retry 5 --retry-delay 10 -o "${TARBALL}" "${URL}"
  tar -xf "${TARBALL}" -C "${BUILD_DIR}"
fi

CC="$(xcrun -sdk iphoneos --find clang)"
CXX="$(xcrun -sdk iphoneos --find clang++)"

cmake -G Ninja \
  -S "${SRC_DIR}/runtimes" \
  -B "${BUILD_DIR}/cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="${SDK}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libc++abi" \
  -DLIBCXX_ENABLE_SHARED=ON \
  -DLIBCXX_ENABLE_STATIC=OFF \
  -DLIBCXXABI_ENABLE_SHARED=ON \
  -DLIBCXX_INSTALL_LIBRARY=ON \
  -DLIBCXXABI_INSTALL_LIBRARY=ON \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}"

ninja -C "${BUILD_DIR}/cmake" install

if ! nm -gU "${INSTALL_DIR}/lib/libc++.1.dylib" | grep -q '__ZTVNSt3__13pmr15memory_resourceE'; then
  echo "error: built libc++.1.dylib is missing std::pmr::memory_resource vtable" >&2
  exit 1
fi

echo "Installed iOS libc++ to ${INSTALL_DIR}"
