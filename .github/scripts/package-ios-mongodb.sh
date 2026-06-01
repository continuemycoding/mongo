#!/usr/bin/env bash
# 参考 cpython build-binaries 思路：prefix 目录 + rpath 修正 + ad-hoc 签名 + 入口脚本。
# 必须整目录部署（bin/ + lib/ + data/ 同级），不能只拷贝 mongod 单个文件。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:?usage: package-ios-mongodb.sh <install-dir> [dest-dir] [entitlements] [libcxx-prefix]}"
DEST="${2:-mongo-ios-arm64}"
ENT="${3:-.github/ios-mongodb.entitlements}"
LIBCXX_PREFIX="${4:-${IOS_LIBCXX_DIR:-${REPO_ROOT}/.ios-libcxx}}"

if [[ ! -f "${SRC}/bin/mongod" ]]; then
  echo "error: ${SRC}/bin/mongod not found" >&2
  exit 1
fi

if [[ ! -f "${ENT}" ]]; then
  echo "error: entitlements not found: ${ENT}" >&2
  exit 1
fi

find_libcxx_libdir() {
  local root="$1"
  local candidate
  for candidate in \
    "${root}/lib" \
    "${root}/lib/arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"; do
    if [[ -d "${candidate}" ]]; then
      if compgen -G "${candidate}/libc++"*.dylib >/dev/null; then
        if compgen -G "${candidate}/libc++abi"*.dylib >/dev/null; then
          echo "${candidate}"
          return 0
        fi
      fi
    fi
  done
  return 1
}

LIBCXX_LIB_DIR="$(find_libcxx_libdir "${LIBCXX_PREFIX}")" || {
  echo "error: iOS libc++ not found under ${LIBCXX_PREFIX}" >&2
  echo "Run .github/scripts/build-ios-libcxx.sh first." >&2
  exit 1
}

echo "Using iOS libc++ from: ${LIBCXX_LIB_DIR}"

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

# 复制 iOS libc++ 全部 Mach-O 文件（含 1.0.dylib 实体，不能只拷符号链接）。
bundle_libcxx() {
  local src_dir="$1"
  local file base real
  shopt -s nullglob
  for file in "${src_dir}"/libc++*.dylib "${src_dir}"/libc++*.1.*.dylib \
              "${src_dir}"/libc++abi*.dylib "${src_dir}"/libc++abi*.1.*.dylib; do
    [[ -e "${file}" ]] || continue
    if [[ -L "${file}" ]]; then
      real="$(cd "${src_dir}" && readlink "${file}")"
      if [[ "${real}" != /* ]]; then
        real="${src_dir}/${real}"
      fi
      if [[ -f "${real}" ]]; then
        cp -a "${real}" "${DEST}/lib/$(basename "${real}")"
      fi
      cp -a "${file}" "${DEST}/lib/$(basename "${file}")"
    else
      cp -a "${file}" "${DEST}/lib/$(basename "${file}")"
    fi
  done
  shopt -u nullglob
}

bundle_libcxx "${LIBCXX_LIB_DIR}"

if ! compgen -G "${DEST}/lib/libc++"*.dylib >/dev/null; then
  echo "error: failed to bundle libc++ into ${DEST}/lib" >&2
  exit 1
fi
if ! compgen -G "${DEST}/lib/libc++abi"*.dylib >/dev/null; then
  echo "error: failed to bundle libc++abi into ${DEST}/lib" >&2
  exit 1
fi

for bundled in "${DEST}/lib"/libc++*.dylib "${DEST}/lib"/libc++abi*.dylib; do
  [[ -e "${bundled}" ]] && scan_deps "${bundled}"
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

pick_bundled_name() {
  local pattern="$1"
  local candidate
  shopt -s nullglob
  for candidate in ${pattern}; do
    if [[ -f "${candidate}" || -L "${candidate}" ]]; then
      basename "${candidate}"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

redirect_libcxx() {
  local file="$1"
  local dep new_path base
  local cpp_name abi_name
  cpp_name="$(pick_bundled_name "${DEST}/lib/libc++.1.dylib ${DEST}/lib/libc++.dylib")" || true
  abi_name="$(pick_bundled_name "${DEST}/lib/libc++abi.1.dylib ${DEST}/lib/libc++abi.dylib")" || true

  for dep in \
    "/usr/lib/libc++.1.dylib" \
    "/usr/lib/libc++.dylib" \
    "/usr/lib/libc++abi.dylib" \
    "/usr/lib/libc++abi.1.dylib" \
    "@rpath/libc++.1.dylib" \
    "@rpath/libc++.dylib" \
    "@rpath/libc++abi.dylib" \
    "@rpath/libc++abi.1.dylib"; do
    base="$(basename "${dep}")"
    if [[ -f "${DEST}/lib/${base}" || -L "${DEST}/lib/${base}" ]]; then
      new_path="$(libcxx_path_for "${file}" "${base}")"
      install_name_tool -change "${dep}" "${new_path}" "${file}" 2>/dev/null || true
    fi
  done

  if [[ -n "${cpp_name}" ]]; then
    new_path="$(libcxx_path_for "${file}" "${cpp_name}")"
    for dep in "/usr/lib/libc++.1.dylib" "/usr/lib/libc++.dylib" "@rpath/libc++.1.dylib" "@rpath/libc++.dylib"; do
      install_name_tool -change "${dep}" "${new_path}" "${file}" 2>/dev/null || true
    done
  fi
  if [[ -n "${abi_name}" ]]; then
    new_path="$(libcxx_path_for "${file}" "${abi_name}")"
    for dep in "/usr/lib/libc++abi.dylib" "/usr/lib/libc++abi.1.dylib" "@rpath/libc++abi.dylib" "@rpath/libc++abi.1.dylib"; do
      install_name_tool -change "${dep}" "${new_path}" "${file}" 2>/dev/null || true
    done
  fi
}

fix_rpaths() {
  local file="$1"
  local dep base new_path

  if [[ "${file}" == "${DEST}/bin/"* ]]; then
    :
  else
    base="$(basename "${file}")"
    install_name_tool -id "@loader_path/${base}" "${file}" 2>/dev/null || true
  fi

  install_name_tool -add_rpath "@executable_path/../lib" "${file}" 2>/dev/null || true

  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"
    dep="${dep%"${dep##*[![:space:]]}"}"
    [[ -z "${dep}" ]] && continue
    base="$(basename "${dep}")"
    if [[ -f "${DEST}/lib/${base}" || -L "${DEST}/lib/${base}" ]]; then
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
echo "Contents:"
find "${DEST}" -maxdepth 2 -type f | sort | sed 's/^/  /'
echo
echo "mongod libc++ deps:"
otool -L "${DEST}/bin/mongod" | grep -E 'libc\+\+|libc++abi' || true
echo
echo "Deploy the whole ${DEST}/ directory; run: ./run-mongod [--help]"

if otool -L "${DEST}/bin/mongod" | grep -q '/usr/lib/libc++'; then
  echo "error: mongod still links against system /usr/lib/libc++" >&2
  exit 1
fi
