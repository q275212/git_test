#!/bin/bash
#
# KernelSU 独立编译脚本
# 目标产物: android14-6.1.112_2024-11-boot-gz.img.gz
#
# 编译流程概述:
#   阶段1: 下载 Google GKI 内核源码 (android14-6.1-2024-11 分支)
#   阶段2: 将 KernelSU 驱动注入内核源码树
#   阶段3: 处理 ABI 符号导出
#   阶段4: 使用 bazel 编译内核，产出 Image / Image.lz4
#   阶段5: 使用 mkbootimg 将 Image.gz 打包为 boot-gz.img
#   阶段6: 使用 avbtool 添加 AVB 签名
#   阶段7: gzip 压缩最终产物
#
# 运行环境要求:
#   - Ubuntu 22.04+ (推荐)
#   - 至少 50GB 磁盘空间
#   - 至少 16GB 内存
#   - 需要联网下载源码和工具链
#
# 用法:
#   chmod +x build_kernelsu_boot.sh
#   ./build_kernelsu_boot.sh
#

set -euo pipefail

# ============================================================
# 配置区域 - 可根据需要修改
# ============================================================

# 内核版本配置
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
KERNEL_SUBLEVEL="112"
OS_PATCH_LEVEL="2024-11"

# 由以上参数自动拼接
VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"                          # android14-6.1
VERSION_NAME="${ANDROID_VERSION}-${KERNEL_VERSION}.${KERNEL_SUBLEVEL}"  # android14-6.1.112
TAG="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"            # android14-6.1-2024-11

# KernelSU 仓库 (可改为你自己的 fork)
KERNELSU_REPO="https://github.com/tiann/KernelSU"
KERNELSU_BRANCH="main"  # 或指定 tag，如 "v1.0.2"

# 工作目录
WORKDIR="$(pwd)/kernelsu_build"
KERNEL_DIR="${WORKDIR}/android-kernel"
KERNELSU_DIR="${WORKDIR}/KernelSU"
TOOLS_DIR="${WORKDIR}/tools"
OUTPUT_DIR="${WORKDIR}/output"

# boot image 签名密钥 (留空则使用 Google 测试密钥)
BOOT_SIGN_KEY=""

# 是否使用 ccache 加速编译
USE_CCACHE=true

# ============================================================
# 函数定义
# ============================================================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

err() {
    echo "[错误] $*" >&2
    exit 1
}

# 检查并安装依赖
install_dependencies() {
    log "检查并安装编译依赖..."
    sudo apt-get update
    sudo apt-get install -y \
        git curl wget python3 python3-pip \
        repo bc bison build-essential \
        flex libssl-dev libelf-dev \
        ccache zip unzip rsync \
        lz4 zlib1g-dev
}

# 克隆 KernelSU 源码
clone_kernelsu() {
    log "克隆 KernelSU 源码..."
    if [ -d "${KERNELSU_DIR}" ]; then
        log "KernelSU 目录已存在，更新中..."
        cd "${KERNELSU_DIR}"
        git fetch --all
        git checkout "${KERNELSU_BRANCH}"
        git pull || true
        cd "${WORKDIR}"
    else
        git clone "${KERNELSU_REPO}" "${KERNELSU_DIR}"
        cd "${KERNELSU_DIR}"
        git checkout "${KERNELSU_BRANCH}" || true
        cd "${WORKDIR}"
    fi

    # 计算 KernelSU 版本号 (与 CI 保持一致: commit 数 + 10200)
    cd "${KERNELSU_DIR}"
    export KSU_VERSION=$(($(git rev-list --count HEAD) + 10200))
    log "KernelSU 版本号: ${KSU_VERSION}"
    cd "${WORKDIR}"
}

# 下载 Google GKI 内核源码
setup_kernel_source() {
    log "下载 GKI 内核源码 (分支: common-${TAG})..."
    log "这可能需要较长时间，取决于网络速度..."

    mkdir -p "${KERNEL_DIR}" && cd "${KERNEL_DIR}"

    # 使用 repo 初始化并同步 Google 内核 manifest
    repo init --depth=1 \
        --u https://android.googlesource.com/kernel/manifest \
        -b "common-${TAG}" \
        --repo-rev=v2.16

    # 检查分支是否已被标记为 deprecated
    REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common "${TAG}" || true)
    DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml
    if echo "${REMOTE_BRANCH}" | grep -q deprecated; then
        log "检测到 deprecated 分支，自动修正 manifest..."
        sed -i "s/\"${TAG}\"/\"deprecated\/${TAG}\"/g" "${DEFAULT_MANIFEST_PATH}"
    fi

    repo sync -c -j"$(nproc --all)" --no-tags
    log "内核源码下载完成"
    cd "${WORKDIR}"
}

# 将 KernelSU 注入内核源码树
setup_kernelsu_in_tree() {
    log "将 KernelSU 驱动注入内核源码树..."
    cd "${KERNEL_DIR}"

    GKI_ROOT=$(pwd)

    # 创建符号链接: common/drivers/kernelsu -> KernelSU/kernel
    ln -sf "${KERNELSU_DIR}/kernel" "${GKI_ROOT}/common/drivers/kernelsu"

    # 修改 drivers/Makefile，添加 KernelSU 编译入口
    DRIVER_MAKEFILE="${GKI_ROOT}/common/drivers/Makefile"
    DRIVER_KCONFIG="${GKI_ROOT}/common/drivers/Kconfig"

    grep -q "kernelsu" "${DRIVER_MAKEFILE}" || \
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "${DRIVER_MAKEFILE}"

    # 修改 drivers/Kconfig，添加 KernelSU 配置菜单
    grep -q "kernelsu" "${DRIVER_KCONFIG}" || \
        sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "${DRIVER_KCONFIG}"

    # 修复高版本 glibc 的编译兼容性问题
    GLIBC_VERSION=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')
    log "系统 glibc 版本: ${GLIBC_VERSION}"
    if [ "$(printf '%s\n' "2.38" "${GLIBC_VERSION}" | sort -V | head -n1)" = "2.38" ]; then
        log "修补 resolve_btfids/Makefile 以兼容 glibc >= 2.38..."
        cd "${GKI_ROOT}/common/"
        sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' \
            tools/bpf/resolve_btfids/Makefile || log "无需修补"
    fi

    log "KernelSU 注入完成"
    cd "${WORKDIR}"
}

# 处理 ABI 符号导出
setup_symbols() {
    log "处理 GKI ABI 符号导出..."
    cd "${KERNEL_DIR}"

    COMMON_ROOT="${KERNEL_DIR}/common"
    ABI_XML="${COMMON_ROOT}/android/abi_gki_aarch64.xml"
    SYMBOL_LIST="${COMMON_ROOT}/android/abi_gki_aarch64"

    if [ -f "${SYMBOL_LIST}" ] && [ -f "${ABI_XML}" ]; then
        log "添加 KernelSU 所需符号到 ABI 符号列表..."
        cat "${KERNELSU_DIR}/kernel/export_symbol.txt" | \
            awk '{sub("[ \t]+","");print "  "$0}' >> "${SYMBOL_LIST}"
    else
        log "未找到 ABI 符号列表文件，跳过"
    fi

    cd "${WORKDIR}"
}

# 清理工作目录，避免 dirty 标记
clean_working_directory() {
    log "清理工作目录，避免编译产物带 dirty 后缀..."
    cd "${KERNEL_DIR}"

    # 移除 protected exports (避免 bazel 构建报错)
    if [ -f common/BUILD.bazel ]; then
        [ -f android/abi_gki_protected_exports_aarch64 ] || \
            sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' common/BUILD.bazel
    fi
    rm -f common/android/abi_gki_protected_exports_* || true

    # 提交所有修改
    git config --global user.email "builder@kernelsu.local"
    git config --global user.name "KernelSU-Builder"
    cd common/ && git add -A && git commit -a -m "Add KernelSU" || true

    cd "${WORKDIR}"
}

# 编译内核
build_kernel() {
    log "开始编译内核 (${VERSION_NAME})..."
    log "这将花费较长时间 (通常 30-60 分钟)..."
    cd "${KERNEL_DIR}"

    # 设置 ccache
    if [ "${USE_CCACHE}" = true ]; then
        export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
        export CCACHE_NOHASHDIR="true"
        export CCACHE_HARDLINK="true"
        export CCACHE_DIR="${WORKDIR}/.ccache"
        mkdir -p "${CCACHE_DIR}"
    fi

    # android14-6.1 使用 bazel 构建系统
    # (android12-5.10 等旧版本使用 build/build.sh)
    if [ -e build/build.sh ]; then
        # 旧版构建系统
        log "使用 build/build.sh 构建..."
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 \
            build/build.sh CC="/usr/bin/ccache clang"
    else
        # 新版 bazel 构建系统 (android14-5.15, android14-6.1 等)
        log "使用 bazel 构建系统..."
        tools/bazel run \
            --disk_cache="${WORKDIR}/.bazel_cache" \
            --config=fast \
            --config=stamp \
            --lto=thin \
            //common:kernel_aarch64_dist -- --dist_dir=dist
    fi

    log "内核编译完成"
    cd "${WORKDIR}"
}

# 下载打包工具链
download_tools() {
    log "下载 boot image 打包工具链..."
    mkdir -p "${TOOLS_DIR}" && cd "${TOOLS_DIR}"

    AOSP_MIRROR="https://android.googlesource.com"
    BRANCH="main-kernel-build-2024"

    if [ ! -d "build-tools" ]; then
        git clone "${AOSP_MIRROR}/platform/prebuilts/build-tools" \
            -b "${BRANCH}" --depth 1 build-tools
    fi

    if [ ! -d "kernel-build-tools" ]; then
        git clone "${AOSP_MIRROR}/kernel/prebuilts/build-tools" \
            -b "${BRANCH}" --depth 1 kernel-build-tools
    fi

    if [ ! -d "mkbootimg" ]; then
        git clone "${AOSP_MIRROR}/platform/system/tools/mkbootimg" \
            -b "${BRANCH}" --depth 1 mkbootimg
    fi

    # 设置自定义签名密钥 (如果提供)
    if [ -n "${BOOT_SIGN_KEY}" ] && [ -f "${BOOT_SIGN_KEY}" ]; then
        log "使用自定义 boot 签名密钥..."
        cp "${BOOT_SIGN_KEY}" "${TOOLS_DIR}/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"
    fi

    cd "${WORKDIR}"
}

# 打包 boot image 并压缩
build_boot_images() {
    log "打包 boot image..."
    mkdir -p "${OUTPUT_DIR}"

    # 定位编译产物目录
    DIST_DIR="${KERNEL_DIR}/out/${VERSION}/dist"
    if [ ! -d "${DIST_DIR}" ]; then
        DIST_DIR="${KERNEL_DIR}/dist"
    fi

    if [ ! -f "${DIST_DIR}/Image" ]; then
        err "未找到编译产物 Image，编译可能失败了"
    fi

    # 设置工具路径
    AVBTOOL="${TOOLS_DIR}/kernel-build-tools/linux-x86/bin/avbtool"
    GZIP="${TOOLS_DIR}/build-tools/path/linux-x86/gzip"
    LZ4="${TOOLS_DIR}/build-tools/path/linux-x86/lz4"
    MKBOOTIMG="${TOOLS_DIR}/mkbootimg/mkbootimg.py"
    AVB_KEY="${TOOLS_DIR}/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"

    cd "${OUTPUT_DIR}"
    cp "${DIST_DIR}/Image" ./
    cp "${DIST_DIR}/Image.lz4" ./ || true

    # 1. 生成 Image.gz
    log "生成 Image.gz..."
    ${GZIP} -n -k -f -9 Image > Image.gz

    # 2. 生成 boot.img (未压缩内核)
    log "生成 boot.img..."
    python3 ${MKBOOTIMG} --header_version 4 --kernel Image --output boot.img
    ${AVBTOOL} add_hash_footer \
        --partition_name boot \
        --partition_size $((64 * 1024 * 1024)) \
        --image boot.img \
        --algorithm SHA256_RSA2048 \
        --key "${AVB_KEY}"

    # 3. 生成 boot-gz.img (gzip 压缩内核) — 这就是目标产物的核心
    log "生成 boot-gz.img..."
    python3 ${MKBOOTIMG} --header_version 4 --kernel Image.gz --output boot-gz.img
    ${AVBTOOL} add_hash_footer \
        --partition_name boot \
        --partition_size $((64 * 1024 * 1024)) \
        --image boot-gz.img \
        --algorithm SHA256_RSA2048 \
        --key "${AVB_KEY}"

    # 4. 生成 boot-lz4.img (lz4 压缩内核)
    if [ -f Image.lz4 ]; then
        log "生成 boot-lz4.img..."
        python3 ${MKBOOTIMG} --header_version 4 --kernel Image.lz4 --output boot-lz4.img
        ${AVBTOOL} add_hash_footer \
            --partition_name boot \
            --partition_size $((64 * 1024 * 1024)) \
            --image boot-lz4.img \
            --algorithm SHA256_RSA2048 \
            --key "${AVB_KEY}"
    fi

    # 5. 最终压缩: boot*.img -> *.img.gz，并按 CI 命名规则重命名
    log "压缩并重命名最终产物..."
    for image in boot*.img; do
        ${GZIP} -n -f -9 "${image}"
        mv "${image}.gz" "${VERSION_NAME}_${OS_PATCH_LEVEL}-${image}.gz"
    done

    log "========================================="
    log "编译完成，产物列表:"
    ls -lh "${OUTPUT_DIR}"/*.img.gz
    log "========================================="
    log ""
    log "目标文件: ${OUTPUT_DIR}/${VERSION_NAME}_${OS_PATCH_LEVEL}-boot-gz.img.gz"
    log ""
    log "该文件可直接通过 fastboot 刷入:"
    log "  fastboot flash boot ${VERSION_NAME}_${OS_PATCH_LEVEL}-boot-gz.img.gz"

    cd "${WORKDIR}"
}

# ============================================================
# 主流程
# ============================================================

main() {
    log "========================================="
    log "KernelSU Boot Image 编译脚本"
    log "目标: ${VERSION_NAME}_${OS_PATCH_LEVEL}-boot-gz.img.gz"
    log "========================================="

    mkdir -p "${WORKDIR}"

    install_dependencies
    clone_kernelsu
    setup_kernel_source
    setup_kernelsu_in_tree
    setup_symbols
    clean_working_directory
    download_tools
    build_kernel
    build_boot_images

    log "全部完成!"
}

main "$@"
