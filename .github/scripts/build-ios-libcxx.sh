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
CMAKE_DIR="${BUILD_DIR}/cmake"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="${SDK}"
DEPLOY="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
TARGET="arm64-apple-ios${DEPLOY}"

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

# 必须用 runtimes/ 独立构建；从 llvm/ 入口会拉起 TableGen 并在 iOS 交叉编译下失败。
# 不要设 CMAKE_SYSTEM_NAME=iOS：LLVM HandleLLVMOptions 仅识别 Darwin，设 iOS 会误加 GNU ld 的 -Wl,-z,defs。
# 显式指定 libcxxabi 头路径，避免 exception.cpp 报 cxxabi.h not found。
rm -rf "${CMAKE_DIR}"
cmake -G Ninja \
  -S "${SRC_DIR}/runtimes" \
  -B "${CMAKE_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="${SDK}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DCMAKE_C_COMPILER_TARGET="${TARGET}" \
  -DCMAKE_CXX_COMPILER_TARGET="${TARGET}" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET}" \
  -DLLVM_ENABLE_RUNTIMES="libcxxabi;libcxx" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_ENABLE_SHARED=ON \
  -DLIBCXX_ENABLE_STATIC=OFF \
  -DLIBCXXABI_ENABLE_SHARED=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
  -DLIBCXX_INSTALL_LIBRARY=ON \
  -DLIBCXXABI_INSTALL_LIBRARY=ON \
  -DCMAKE_C_FLAGS="-isystem ${SRC_DIR}/libcxxabi/include" \
  -DCMAKE_CXX_FLAGS="-isystem ${SRC_DIR}/libcxxabi/include"

# 先编 libcxxabi 再编 libc++，与 LLVM 默认 layering 一致。
ninja -C "${CMAKE_DIR}" cxxabi_shared cxx_shared
ninja -C "${CMAKE_DIR}" install

normalize_libcxx_install() {
  local libdir="${INSTALL_DIR}/lib"
  local base real
  shopt -s nullglob
  for base in "${libdir}"/libc++*.1.*.dylib "${libdir}"/libc++abi*.1.*.dylib; do
    [[ -f "${base}" ]] || continue
    ln -sf "$(basename "${base}")" "${libdir}/$(echo "$(basename "${base}")" | sed -E 's/\.[0-9]+\.[0-9]+\.dylib$/.dylib/')"
    ln -sf "$(basename "${base}")" "${libdir}/$(echo "$(basename "${base}")" | sed -E 's/\.[0-9]+\.[0-9]+\.dylib$/.1.dylib/')"
  done
  shopt -u nullglob
}

normalize_libcxx_install

if ! compgen -G "${INSTALL_DIR}/lib/libc++"*.dylib >/dev/null; then
  echo "error: ${INSTALL_DIR}/lib is missing libc++ dylibs after install" >&2
  ls -la "${INSTALL_DIR}/lib" >&2 || true
  exit 1
fi
if ! compgen -G "${INSTALL_DIR}/lib/libc++abi"*.dylib >/dev/null; then
  echo "error: ${INSTALL_DIR}/lib is missing libc++abi dylibs after install" >&2
  ls -la "${INSTALL_DIR}/lib" >&2 || true
  exit 1
fi

if ! nm -gU "${INSTALL_DIR}/lib/libc++.1.dylib" 2>/dev/null | grep -q '__ZTVNSt3__13pmr15memory_resourceE'; then
  # libc++.1.dylib 可能是 symlink，解析后再检查
  real_cpp="$(cd "${INSTALL_DIR}/lib" && readlink libc++.1.dylib 2>/dev/null || echo libc++.1.dylib)"
  if ! nm -gU "${INSTALL_DIR}/lib/${real_cpp}" | grep -q '__ZTVNSt3__13pmr15memory_resourceE'; then
    echo "error: built libc++.dylib is missing std::pmr::memory_resource vtable" >&2
    exit 1
  fi
fi

echo "Installed iOS libc++ to ${INSTALL_DIR}"
