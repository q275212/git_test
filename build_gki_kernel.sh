#!/bin/bash
#
# 纯 GKI 内核编译脚本 (不含 KernelSU)
#
# 仅从 Google 源码编译原版 GKI 内核并打包 boot image
#
# 用法:
#   chmod +x build_gki_kernel.sh
#   ./build_gki_kernel.sh
#
# 环境要求: Ubuntu 22.04+, 50GB 磁盘, 16GB 内存
#
        tools/bazel run --config=fast --config=stamp --lto=thin  //common:kernel_aarch64_dist -- --dist_dir=dist
set -euo pipefail

# ============================================================
# 配置区域
# ============================================================

ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
KERNEL_SUBLEVEL="112"
OS_PATCH_LEVEL="2024-11"

TAG="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
VERSION_NAME="${ANDROID_VERSION}-${KERNEL_VERSION}.${KERNEL_SUBLEVEL}"

WORKDIR="$(pwd)/gki_build"
KERNEL_DIR="${WORKDIR}/android-kernel"
TOOLS_DIR="${WORKDIR}/tools"
OUTPUT_DIR="${WORKDIR}/output"

USE_CCACHE=true

# ============================================================
# 函数
# ============================================================

repo init --depth=1 \
    --u https://android.googlesource.com/kernel/manifest \
    -b common-android14-6.1-2024-11 --repo-rev=v2.16
log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[错误] $*" >&2; exit 1; }

# 安装依赖
install_deps() {
    log "安装编译依赖..."
    sudo apt-get update
    sudo apt-get install -y \
        git curl python3 python3-pip repo \
        bc bison build-essential flex \
        libssl-dev libelf-dev ccache zip unzip lz4
}

# 下载内核源码
fetch_kernel() {
    log "下载 GKI 内核源码 (common-${TAG})..."
    mkdir -p "${KERNEL_DIR}" && cd "${KERNEL_DIR}"

    repo init --depth=1 \
        --u https://android.googlesource.com/kernel/manifest \
        -b "common-${TAG}" --repo-rev=v2.16

    # 处理 deprecated 分支
    REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common "${TAG}" || true)
    if echo "${REMOTE_BRANCH}" | grep -q deprecated; then
        log "检测到 deprecated 分支，自动修正..."
        sed -i "s/\"${TAG}\"/\"deprecated\/${TAG}\"/g" .repo/manifests/default.xml
    fi

    repo sync -c -j"$(nproc --all)" --no-tags
    log "源码下载完成"
    cd "${WORKDIR}"
}

# 编译内核
build_kernel() {
    log "开始编译内核..."
    cd "${KERNEL_DIR}"

    if [ "${USE_CCACHE}" = true ]; then
        export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
        export CCACHE_NOHASHDIR="true"
        export CCACHE_HARDLINK="true"
        export CCACHE_DIR="${WORKDIR}/.ccache"
        mkdir -p "${CCACHE_DIR}"
    fi

    # android14-6.1 使用 bazel 构建; 旧版本用 build/build.sh
    if [ -e build/build.sh ]; then
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 \
            build/build.sh CC="/usr/bin/ccache clang"
    else
        tools/bazel run \
            --disk_cache="${WORKDIR}/.bazel_cache" \
            --config=fast --config=stamp --lto=thin \
            //common:kernel_aarch64_dist -- --dist_dir=dist
    fi

    log "内核编译完成"
    cd "${WORKDIR}"
}

# 下载打包工具
fetch_tools() {
    log "下载 boot image 打包工具..."
    mkdir -p "${TOOLS_DIR}" && cd "${TOOLS_DIR}"

    AOSP="https://android.googlesource.com"
    BRANCH="main-kernel-build-2024"

    [ -d build-tools ]        || git clone "${AOSP}/platform/prebuilts/build-tools"  -b "${BRANCH}" --depth 1 build-tools
    [ -d kernel-build-tools ] || git clone "${AOSP}/kernel/prebuilts/build-tools"    -b "${BRANCH}" --depth 1 kernel-build-tools
    [ -d mkbootimg ]          || git clone "${AOSP}/platform/system/tools/mkbootimg" -b "${BRANCH}" --depth 1 mkbootimg

    cd "${WORKDIR}"
}

# 打包 boot image
pack_boot() {
    log "打包 boot image..."
    mkdir -p "${OUTPUT_DIR}"

    # 定位编译产物
    DIST_DIR="${KERNEL_DIR}/dist"
    [ -d "${DIST_DIR}" ] || DIST_DIR="${KERNEL_DIR}/out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist"
    [ -f "${DIST_DIR}/Image" ] || err "未找到 Image，编译可能失败"

    AVBTOOL="${TOOLS_DIR}/kernel-build-tools/linux-x86/bin/avbtool"
    GZIP="${TOOLS_DIR}/build-tools/path/linux-x86/gzip"
    MKBOOTIMG="${TOOLS_DIR}/mkbootimg/mkbootimg.py"
    AVB_KEY="${TOOLS_DIR}/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"

    cd "${OUTPUT_DIR}"
    cp "${DIST_DIR}/Image" ./
    cp "${DIST_DIR}/Image.lz4" ./ 2>/dev/null || true

    # Image -> Image.gz
    ${GZIP} -n -k -f -9 Image > Image.gz

    # boot.img (原始内核)
    python3 ${MKBOOTIMG} --header_version 4 --kernel Image --output boot.img
    ${AVBTOOL} add_hash_footer --partition_name boot --partition_size $((64*1024*1024)) \
        --image boot.img --algorithm SHA256_RSA2048 --key "${AVB_KEY}"

    # boot-gz.img (gzip 压缩内核)
    python3 ${MKBOOTIMG} --header_version 4 --kernel Image.gz --output boot-gz.img
    ${AVBTOOL} add_hash_footer --partition_name boot --partition_size $((64*1024*1024)) \
        --image boot-gz.img --algorithm SHA256_RSA2048 --key "${AVB_KEY}"

    # boot-lz4.img (lz4 压缩内核)
    if [ -f Image.lz4 ]; then
        python3 ${MKBOOTIMG} --header_version 4 --kernel Image.lz4 --output boot-lz4.img
        ${AVBTOOL} add_hash_footer --partition_name boot --partition_size $((64*1024*1024)) \
            --image boot-lz4.img --algorithm SHA256_RSA2048 --key "${AVB_KEY}"
    fi

    # 最终压缩并重命名
    for img in boot*.img; do
        ${GZIP} -n -f -9 "${img}"
        mv "${img}.gz" "${VERSION_NAME}_${OS_PATCH_LEVEL}-${img}.gz"
    done

    log "========================================="
    log "产物列表:"
    ls -lh "${OUTPUT_DIR}"/*.img.gz
    log "========================================="
    cd "${WORKDIR}"
}

# ============================================================
# 主流程
# ============================================================

main() {
    log "纯 GKI 内核编译 (${VERSION_NAME})"
    mkdir -p "${WORKDIR}"

    # install_deps
    fetch_kernel
    fetch_tools
    build_kernel
    pack_boot

    log "全部完成!"
}

main "$@"
