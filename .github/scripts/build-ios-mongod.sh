#!/usr/bin/env bash
# 为越狱 iOS 真机（arm64-apple-ios）交叉编译 mongod。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="${SDK}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
TARGET="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}"

echo "iOS SDK: ${SDK}"
echo "Target:  ${TARGET}"

# MongoDB macOS 构建依赖 Homebrew LLVM 19（见 docs/building.md）
# Bazel 工具链用 readlink -f，macOS 需 GNU coreutils 提供的 readlink。
need_brew=()
if ! brew --prefix llvm@19 >/dev/null 2>&1; then
  need_brew+=(llvm@19 lld@19)
fi
if ! brew --prefix coreutils >/dev/null 2>&1; then
  need_brew+=(coreutils)
fi
if [[ "${#need_brew[@]}" -gt 0 ]]; then
  echo "Installing Homebrew packages: ${need_brew[*]}"
  brew install "${need_brew[@]}"
fi
LLVM_PREFIX="$(brew --prefix llvm@19)"
LLD_PREFIX="$(brew --prefix lld@19)"
COREUTILS_PREFIX="$(brew --prefix coreutils)"
export PATH="${COREUTILS_PREFIX}/libexec/gnubin:${LLVM_PREFIX}/bin:${LLD_PREFIX}/bin:${PATH}"
echo "LLVM: ${LLVM_PREFIX}"
/bin/bash -c "readlink -f '${LLVM_PREFIX}'"

# GitHub Actions macOS 禁止系统 pip 直装（PEP 668），按 Evergreen venv_setup 方式建虚拟环境。
POETRY_VENV="${REPO_ROOT}/.ci-poetry-venv"
PROJECT_VENV="${REPO_ROOT}/.ci-venv"
POETRY_DIR="${REPO_ROOT}/.ci-poetry-dir"
export POETRY_CONFIG_DIR="${POETRY_DIR}/config"
export POETRY_DATA_DIR="${POETRY_DIR}/data"
export POETRY_CACHE_DIR="${POETRY_DIR}/cache"
export PIP_CACHE_DIR="${POETRY_DIR}/pip_cache"
export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring
export VIRTUAL_ENV_DISABLE_PROMPT=yes

python3 -m venv "${POETRY_VENV}"
"${POETRY_VENV}/bin/python3" -m pip install --disable-pip-version-check -q "pip==25.3" "wheel==0.45.1"
"${POETRY_VENV}/bin/python3" -m pip install --disable-pip-version-check -q -r "${REPO_ROOT}/poetry_requirements.txt"

python3 -m venv "${PROJECT_VENV}"
# shellcheck source=/dev/null
source "${PROJECT_VENV}/bin/activate"
python -m pip install --disable-pip-version-check -q "pip==25.3" "wheel==0.45.1"

POETRY="${POETRY_VENV}/bin/python3 -m poetry"
for i in 1 2 3 4 5; do
  if ${POETRY} install --no-root --sync; then
    break
  fi
  if [[ "${i}" -eq 5 ]]; then
    echo "error: poetry install failed after 5 attempts" >&2
    exit 1
  fi
  echo "poetry install failed, retrying (${i}/5)..."
  sleep "${i}"
done

python buildscripts/install_bazel.py
export PATH="${HOME}/.local/bin:${PATH}"

# -target / -isysroot 需跟当前 Xcode SDK 绑定，在 shell 里注入；bazelrc.ios 管 ssl 与 +crc
IOS_CFLAGS=(
  "-target" "${TARGET}"
  "-isysroot" "${SDK}"
)
IOS_LINKOPTS=(
  "-target" "${TARGET}"
  "-isysroot" "${SDK}"
  "-miphoneos-version-min=${IPHONEOS_DEPLOYMENT_TARGET}"
  "-march=armv8-a+crc"
  # 强制链接器使用 iPhoneOS SDK，避免链入 MacOSX.sdk 的 libc++/CoreFoundation
  "-Wl,-syslibroot,${SDK}"
  "-L${SDK}/usr/lib"
  "-F${SDK}/System/Library/Frameworks"
  "-F${SDK}/System/Library/SubFrameworks"
  "-Wl,-platform_version,ios,${IPHONEOS_DEPLOYMENT_TARGET},${IPHONEOS_DEPLOYMENT_TARGET}"
)

# MongoDB 的 bazel wrapper 不支持 --bazelrc= 参数，iOS 相关 flag 直接传入。
bazel_args=(
  build install-mongod
  --config=local
  --config=no-remote-exec
  --//bazel/config:ssl=False
  --//bazel/config:http_client=False
  --//bazel/config:server_js=False
  --//bazel/config:js_engine=none
  --copt=-march=armv8-a+crc
  --copt=-DXP_IOS=1
  --action_env=SDKROOT="${SDK}"
  --action_env=IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET}"
  --disable_warnings_as_errors=True
)
for flag in "${IOS_CFLAGS[@]}"; do
  bazel_args+=(--copt="${flag}")
done
for flag in "${IOS_LINKOPTS[@]}"; do
  bazel_args+=(--linkopt="${flag}")
done

echo "Running: bazel ${bazel_args[*]}"
bazel "${bazel_args[@]}"

echo "Build finished: ${REPO_ROOT}/bazel-bin/install-mongod/bin/mongod"
