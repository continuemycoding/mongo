#!/usr/bin/env bash
# 参考 cpython build-binaries 思路：prefix 目录 + rpath 修正 + ad-hoc 签名 + 入口脚本。
# 必须整目录部署（bin/ + lib/ + data/ 同级），不能只拷贝 mongod 单个文件。
set -euo pipefail

SRC="${1:?usage: package-ios-mongodb.sh <install-dir> [dest-dir] [entitlements] [libcxx-lib-dir]}"
DEST="${2:-mongo-ios-arm64}"
ENT="${3:-.github/ios-mongodb.entitlements}"
LIBCXX_LIB_DIR="${4:-${IOS_LIBCXX_DIR:-.ios-libcxx/lib}}"

if [[ ! -f "${SRC}/bin/mongod" ]]; then
  echo "error: ${SRC}/bin/mongod not found" >&2
  exit 1
fi

if [[ ! -f "${ENT}" ]]; then
  echo "error: entitlements not found: ${ENT}" >&2
  exit 1
fi

if [[ ! -f "${LIBCXX_LIB_DIR}/libc++.1.dylib" || ! -f "${LIBCXX_LIB_DIR}/libc++abi.dylib" ]]; then
  echo "error: iOS libc++ not found in ${LIBCXX_LIB_DIR}" >&2
  echo "Run .github/scripts/build-ios-libcxx.sh first." >&2
  exit 1
fi

rm -rf "${DEST}"
mkdir -p "${DEST}/bin" "${DEST}/lib" "${DEST}/data"

copy_bin() {
  local name="$1"
  if [[ -f "${SRC}/bin/${name}" ]]; then
    cp -a "${SRC}/bin/${name}" "${DEST}/bin/"
    chmod +x "${DEST}/bin/${name}"
  fi
}

copy_bin mongod
copy_bin mongos

# 收集并复制动态库依赖（Bazel install 树 + otool -L 递归）
# 不用 declare -A：macOS 默认 bash 3.2 不支持关联数组
copy_dep() {
  local dep="$1"
  [[ -z "${dep}" ]] && return 0
  case "${dep}" in
    /usr/lib/libc++* | /usr/lib/libc++abi* | /System/* | "${SDKROOT:-}"/* | /Library/Developer/*)
      return 0
      ;;
    /usr/lib/*)
      return 0
      ;;
  esac
  local base resolved
  if [[ "${dep}" == @rpath/* ]]; then
    base="$(basename "${dep}")"
    dep="${SRC}/lib/${base}"
  else
    base="$(basename "${dep}")"
  fi
  if [[ -f "${DEST}/lib/${base}" ]]; then
    return 0
  fi
  if [[ -f "${dep}" ]]; then
    resolved="${dep}"
  elif [[ -f "${SRC}/lib/${base}" ]]; then
    resolved="${SRC}/lib/${base}"
  elif [[ -f "${SRC}/bin/${base}" ]]; then
    resolved="${SRC}/bin/${base}"
  else
    return 0
  fi
  cp -a "${resolved}" "${DEST}/lib/${base}"
  scan_deps "${DEST}/lib/${base}"
}

scan_deps() {
  local macho="$1"
  local dep
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"
    dep="${dep%"${dep##*[![:space:]]}"}"
    [[ -z "${dep}" || "${dep}" == "${macho}:"* ]] && continue
    copy_dep "${dep}"
  done < <(otool -L "${macho}" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

for macho in "${DEST}/bin"/*; do
  [[ -f "${macho}" ]] && scan_deps "${macho}"
done

# 随包带上与编译期 LLVM 头文件匹配的 libc++，避免 dyld 在设备旧版 /usr/lib/libc++.1.dylib 上找不到 std::pmr 符号。
cp -a "${LIBCXX_LIB_DIR}/libc++.1.dylib" "${LIBCXX_LIB_DIR}/libc++abi.dylib" "${DEST}/lib/"
for bundled in "${DEST}/lib"/libc++*.dylib; do
  [[ -f "${bundled}" ]] && scan_deps "${bundled}"
done

libcxx_path_for() {
  local file="$1"
  local base="$2"
  if [[ "${file}" == "${DEST}/bin/"* ]]; then
    echo "@executable_path/../lib/${base}"
  else
    echo "@loader_path/${base}"
  fi
}

redirect_libcxx() {
  local file="$1"
  local dep new_path
  for dep in \
    "/usr/lib/libc++.1.dylib" \
    "/usr/lib/libc++.dylib" \
    "/usr/lib/libc++abi.dylib" \
    "/usr/lib/libc++abi.1.dylib"; do
    base="$(basename "${dep}")"
    if [[ -f "${DEST}/lib/${base}" ]]; then
      new_path="$(libcxx_path_for "${file}" "${base}")"
      install_name_tool -change "${dep}" "${new_path}" "${file}" 2>/dev/null || true
    fi
  done
}

fix_rpaths() {
  local file="$1"
  local id_path dep base new_path

  if [[ "${file}" == "${DEST}/bin/"* ]]; then
    id_path="@executable_path/../lib"
  else
    base="$(basename "${file}")"
    id_path="@loader_path/${base}"
    install_name_tool -id "${id_path}" "${file}" 2>/dev/null || true
  fi

  install_name_tool -add_rpath "@executable_path/../lib" "${file}" 2>/dev/null || true

  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"
    dep="${dep%"${dep##*[![:space:]]}"}"
    [[ -z "${dep}" ]] && continue
    base="$(basename "${dep}")"
    if [[ -f "${DEST}/lib/${base}" ]]; then
      new_path="@loader_path/${base}"
      if [[ "${file}" == "${DEST}/bin/"* ]]; then
        new_path="@executable_path/../lib/${base}"
      fi
      install_name_tool -change "${dep}" "${new_path}" "${file}" 2>/dev/null || true
    fi
  done < <(otool -L "${file}" 2>/dev/null | tail -n +2 | awk '{print $1}')

  redirect_libcxx "${file}"
}

find "${DEST}/bin" "${DEST}/lib" -type f 2>/dev/null | while read -r macho; do
  fix_rpaths "${macho}"
done

# iOS 15+ 越狱 CLI 需 codesign + platform-application
find "${DEST}" -type f | while read -r f; do
  if file -b "${f}" | grep -q 'Mach-O'; then
    codesign -f -s - --entitlements "${ENT}" "${f}"
  fi
done

chmod +x "${DEST}/bin/"* 2>/dev/null || true

# 入口脚本：设置库路径与默认 dbpath，避免只拷贝 mongod 到 ~/bin 导致找不到依赖
cat > "${DEST}/run-mongod" <<'EOF'
#!/bin/sh
ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
export DYLD_LIBRARY_PATH="${ROOT}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
DBPATH="${ROOT}/data"
mkdir -p "${DBPATH}"
exec "${ROOT}/bin/mongod" --dbpath "${DBPATH}" "$@"
EOF
chmod +x "${DEST}/run-mongod"
codesign -f -s - --entitlements "${ENT}" "${DEST}/run-mongod"

echo "Packaged iOS MongoDB CLI: ${DEST}/"
echo "  bin/mongod"
echo "  lib/libc++.1.dylib lib/libc++abi.dylib (+ other deps)"
echo "  run-mongod"
echo "Deploy the whole directory; run: ./run-mongod [--help]"
