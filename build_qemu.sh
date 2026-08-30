#!/usr/bin/env bash
# =============================================================================
# build_qemu.sh — QEMU virt (aarch64) 学习环境一键构建与运行
#
# 用法:
#   ./build_qemu.sh -b              编译三个成果物(busybox/u-boot/kernel)并打包 initramfs
#   ./build_qemu.sh -r [qemu参数]   启动虚拟板卡进入交互式串口终端
#                                   (exit 退出 shell 自动重生; poweroff 关机; reset 真重启;
#                                    Ctrl-A x 强退 QEMU; 其余参数原样传给 qemu, 如 -S -s 配合 gdb)
#   ./build_qemu.sh -r test         验证模式: 自动执行 VERIFY 标记检查并关机(回归用)
#   ./build_qemu.sh -c              删除构建产物(build/ 与 out/)
#   ./build_qemu.sh -h              帮助
#
# 目录约定(均相对本脚本所在目录):
#   busybox/ kernel/ u-boot/        repo sync 的源码树(需含 qemu_defconfig 提交)
#   build/{busybox,uboot,kernel}    O= 构建目录
#   build/rootfs                    busybox install 的 rootfs 骨架(-b 时删除重建)
#   build/rootfs.cpio.gz            initramfs 自动验证版(-r test), 零填充到固定 4MiB
#   build/rootfs-shell.cpio.gz      initramfs 交互终端版(-r), 零填充到固定 4MiB
#   out/boot.log                    最近一次 QEMU 串口日志
#
# 注: build/rootfs/init 与 etc/inittab 均由本脚本在每次 -b 时重新写入,
#     如需定制请修改下方 gen_init(验证版) / gen_init_shell(交互版)。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BUSYBOX="$ROOT/busybox"
SRC_KERNEL="$ROOT/kernel"
SRC_UBOOT="$ROOT/u-boot"
BUILD="$ROOT/build"
OUT="$ROOT/out"
# ---------------------------------------------------------------------------
# 为什么打包两份 initramfs?
#   内核 bootargs/rdinit 烘焙在 U-Boot 的 CONFIG_BOOTCOMMAND 里(见
#   u-boot/configs/qemu_defconfig), 运行期无法按模式传入不同的内核命令行,
#   因此 PID 1 的行为只能由 initramfs 里的 /init 内容决定, 各打一份:
#     rootfs.cpio.gz        自动验证版: /init 打印 VERIFY 标记后 poweroff,
#                           供 -r test 无人值守回归(脚本自动核对串口日志标记);
#     rootfs-shell.cpio.gz  交互终端版: /init 挂载伪文件系统后 exec /sbin/init,
#                           由 /etc/inittab 在 ttyAMA0 上 respawn 常驻 shell,
#                           供 -r 日常交互学习。
#   两份均零填充到固定 4 MiB(0x400000), 同一份烘焙 bootcmd 通吃, -r 只是
#   选择把哪一份加载到 0x60000000, 切换模式无需重新构建或重新打包。
# ---------------------------------------------------------------------------
INITRAMFS="$BUILD/rootfs.cpio.gz"             # 自动验证版(-r test): VERIFY 标记 + poweroff
INITRAMFS_SHELL="$BUILD/rootfs-shell.cpio.gz" # 交互终端版(-r): busybox init + 常驻 shell
INITRAMFS_SIZE=$((4 * 1024 * 1024))    # 0x400000, 与 u-boot qemu_defconfig 的 BOOTCOMMAND 对应
CROSS_PREFIX="aarch64-linux-musl-"
J="$(nproc)"

step()  { echo -e "\e[96m➤  $*\e[0m"; }
ok()    { echo "  ✅ $*"; }
warn()  { echo -e "  ⚠️  $*"; }
error() { echo -e "  ❌ $*" >&2; }
die()   { error "$*"; exit 1; }

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# init 脚本: 挂载伪文件系统 -> 打印验证标记 -> 关机(QEMU 以 exit 0 干净退出)
# ---------------------------------------------------------------------------
gen_init() {
    cat > "$BUILD/rootfs/init" <<'EOF'
#!/bin/sh
# QEMU virt 验证用 init: 挂载伪文件系统 -> 打印验证标记 -> 关机
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "VERIFY-BUSYBOX: userspace is alive, PID 1 = $(cat /proc/1/comm)"
echo "VERIFY-BUSYBOX: $(busybox | head -1)"
echo "VERIFY-KERNEL:  $(uname -a)"
echo "VERIFY-CPU:     $(uname -m), $(nproc) cores, meminfo: $(grep MemTotal /proc/meminfo)"
echo "VERIFY-LS:      $(ls / | tr '\n' ' ')"

echo "ALL-ARTIFACTS-VERIFIED: u-boot -> kernel 7.2.2 -> busybox 1.38.0"
sync
poweroff -f
EOF
    chmod 755 "$BUILD/rootfs/init"
}

# 交互终端版 init: 挂载伪文件系统后交给 busybox init(/etc/inittab) 接管,
# 由 respawn 条目在 ttyAMA0 上常驻 shell —— exit 退出后会自动重生
gen_init_shell() {
    cat > "$BUILD/rootfs/init" <<'EOF'
#!/bin/sh
# QEMU virt 交互模式 init: 挂载伪文件系统 -> 交给 busybox init(/etc/inittab) 接管
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "VERIFY-BUSYBOX: userspace is alive, PID 1 = $(cat /proc/1/comm)"
echo "BOARD-READY: 交互式串口终端, exit 退出后 shell 自动重生, poweroff 关机"
exec /sbin/init
EOF
    chmod 755 "$BUILD/rootfs/init"
    cat > "$BUILD/rootfs/etc/inittab" <<'EOF'
# busybox init: sysinit 做基础设置, ttyAMA0 上常驻 shell (respawn, 退出即重生)
::sysinit:/etc/rc.sh
ttyAMA0::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
    cat > "$BUILD/rootfs/etc/rc.sh" <<'EOF'
#!/bin/sh
hostname qemu-virt
EOF
    chmod 755 "$BUILD/rootfs/etc/rc.sh"
}

build_busybox() {
    step "busybox: qemu_defconfig -> 编译 -> 安装 (前缀已固化在配置里, 全程免 CROSS_COMPILE)"
    make -C "$SRC_BUSYBOX" O="$BUILD/busybox" qemu_defconfig
    make -C "$SRC_BUSYBOX" O="$BUILD/busybox" -j"$J"
    rm -rf "$BUILD/rootfs"
    make -C "$SRC_BUSYBOX" O="$BUILD/busybox" CONFIG_PREFIX="$BUILD/rootfs" install
    cd "$BUILD/rootfs"
    mkdir -p dev proc sys tmp etc root mnt run
    if mknod -m 622 dev/console c 5 1 2>/dev/null && mknod -m 666 dev/null c 1 3 2>/dev/null; then
        ok "设备节点已用 mknod 创建"
    else
        rm -f dev/console dev/null
        warn "容器无 CAP_MKNOD, 打包时回退为内核 gen_init_cpio 生成节点"
    fi
}

build_uboot() {
    step "u-boot: qemu_defconfig -> 编译 (需命令行传 CROSS_COMPILE)"
    make -C "$SRC_UBOOT" O="$BUILD/uboot" CROSS_COMPILE="$CROSS_PREFIX" qemu_defconfig
    make -C "$SRC_UBOOT" O="$BUILD/uboot" CROSS_COMPILE="$CROSS_PREFIX" -j"$J"
}

build_kernel() {
    step "kernel: qemu_defconfig -> 编译 (需 ARCH=arm64 + CROSS_COMPILE)"
    make -C "$SRC_KERNEL" O="$BUILD/kernel" ARCH=arm64 CROSS_COMPILE="$CROSS_PREFIX" qemu_defconfig
    make -C "$SRC_KERNEL" O="$BUILD/kernel" ARCH=arm64 CROSS_COMPILE="$CROSS_PREFIX" -j"$J"
}

pack_initramfs() {    # $1 = 输出文件
    local out="$1"
    step "打包 $(basename "$out") (零填充到 $INITRAMFS_SIZE 字节 = 0x400000)"
    cd "$BUILD/rootfs"
    if [ -e dev/console ] && [ -e dev/null ]; then
        find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9 > "$out"
    else
        [ -x "$BUILD/gen_init_cpio" ] ||
            gcc -O2 -o "$BUILD/gen_init_cpio" "$SRC_KERNEL/usr/gen_init_cpio.c"
        printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
            > "$BUILD/dev.list"
        "$BUILD/gen_init_cpio" "$BUILD/dev.list" > "$BUILD/dev.cpio"
        find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null > "$BUILD/fs.cpio"
        cat "$BUILD/fs.cpio" "$BUILD/dev.cpio" | gzip -9 > "$out"
    fi
    local gz_raw
    gz_raw="$(stat -c%s "$out")"
    if [ "$gz_raw" -gt "$INITRAMFS_SIZE" ]; then
        die "$(basename "$out") 实际 $gz_raw 字节超过固定尺寸 $INITRAMFS_SIZE, 拒绝填充(会截断损坏); 请精简 rootfs 或调大本脚本 INITRAMFS_SIZE 并同步修改 u-boot bootcmd 的 :0x400000"
    fi
    truncate -s "$INITRAMFS_SIZE" "$out"
    ok "$(basename "$out"): 内容 $gz_raw 字节, 填充后 $(stat -c%s "$out") 字节"
}

make_rootfs_verify() {    # 自动验证版: /init 打印 VERIFY 标记后 poweroff
    gen_init
    rm -f "$BUILD/rootfs/etc/inittab" "$BUILD/rootfs/etc/rc.sh"
    pack_initramfs "$INITRAMFS"
}

make_rootfs_shell() {     # 交互终端版: /init 交给 busybox init, inittab 常驻 shell
    gen_init_shell
    pack_initramfs "$INITRAMFS_SHELL"
}

verify_build() {
    step "校验成果物架构 (每一步都验架构, 挡住错误架构的二进制)"
    file -b "$BUILD/busybox/busybox" | grep -q 'ARM aarch64' \
        || die "busybox 架构不是 aarch64: $(file -b "$BUILD/busybox/busybox")"
    file -b "$BUILD/busybox/busybox" | grep -q 'static' \
        || die "busybox 不是静态链接: $(file -b "$BUILD/busybox/busybox")"
    ok "busybox: $(file -b "$BUILD/busybox/busybox" | cut -d, -f1-3)"
    [ -f "$BUILD/kernel/arch/arm64/boot/Image" ] \
        && file -b "$BUILD/kernel/arch/arm64/boot/Image" | grep -qi 'ARM64' \
        || die "Image 缺失或架构不对: $(file -b "$BUILD/kernel/arch/arm64/boot/Image" 2>/dev/null)"
    ok "Image: $(file -b "$BUILD/kernel/arch/arm64/boot/Image" | cut -d, -f1-2)"
    [ -s "$BUILD/uboot/u-boot.bin" ] || die "u-boot.bin 缺失"
    ok "u-boot.bin: $(stat -c%s "$BUILD/uboot/u-boot.bin") 字节"
    step "成果物清单"
    printf '  %-58s %12s\n' \
        "$BUILD/busybox/busybox" "$(stat -c%s "$BUILD/busybox/busybox")" \
        "$BUILD/uboot/u-boot.bin" "$(stat -c%s "$BUILD/uboot/u-boot.bin")" \
        "$BUILD/kernel/arch/arm64/boot/Image" "$(stat -c%s "$BUILD/kernel/arch/arm64/boot/Image")" \
        "$INITRAMFS" "$(stat -c%s "$INITRAMFS")" \
        "$INITRAMFS_SHELL" "$(stat -c%s "$INITRAMFS_SHELL")"
}

do_build() {
    for f in "$SRC_BUSYBOX/configs/qemu_defconfig" \
             "$SRC_KERNEL/arch/arm64/configs/qemu_defconfig" \
             "$SRC_UBOOT/configs/qemu_defconfig"; do
        [ -f "$f" ] || die "缺少 $f, 请 repo sync 到包含 qemu_defconfig 的 main 分支"
    done
    mkdir -p "$BUILD/busybox" "$BUILD/uboot" "$BUILD/kernel"    # kbuild 不会自建 O= 目录
    build_busybox
    build_uboot
    build_kernel
    make_rootfs_verify
    make_rootfs_shell
    verify_build
    step "全部完成: ./build_qemu.sh -r 交互终端 | ./build_qemu.sh -r test 启动验证"
}

do_run() {
    # -r [test] [qemu参数]: 默认交互终端; 参数为 test 时进入验证模式(VERIFY 标记 + 自动关机)
    local verify=0 a
    local qemu_args=()
    for a in "$@"; do
        case "$a" in
            test) verify=1 ;;
            *) qemu_args+=("$a") ;;
        esac
    done
    local cpio="$INITRAMFS_SHELL"   # 默认加载交互终端版
    [ "$verify" -eq 0 ] || cpio="$INITRAMFS"   # test 切换为自动验证版(见"为什么打包两份")

    step "检查成果物"
    local fail=0
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        ok "qemu-system-aarch64: $(qemu-system-aarch64 --version | head -1 | awk '{print $4}')"
    else
        error "找不到 qemu-system-aarch64"; fail=1
    fi
    if [ -s "$BUILD/uboot/u-boot.bin" ]; then
        ok "u-boot.bin: $(stat -c%s "$BUILD/uboot/u-boot.bin") 字节"
    else
        error "缺少 u-boot.bin"; fail=1
    fi
    if [ -f "$BUILD/kernel/arch/arm64/boot/Image" ] \
        && file -b "$BUILD/kernel/arch/arm64/boot/Image" | grep -qi 'ARM64'; then
        ok "Image: $(stat -c%s "$BUILD/kernel/arch/arm64/boot/Image") 字节, ARM64"
    else
        error "缺少 Image 或架构不对"; fail=1
    fi
    if [ -f "$cpio" ] \
        && [ "$(stat -c%s "$cpio")" -eq "$INITRAMFS_SIZE" ] \
        && zcat "$cpio" | cpio -it --quiet 2>/dev/null | grep -q '^init$'; then
        ok "$(basename "$cpio"): $(stat -c%s "$cpio") 字节 (= 0x400000), 含 /init"
    else
        error "$(basename "$cpio") 缺失 / 尺寸不是 0x400000 / 缺少 /init"; fail=1
    fi
    [ "$fail" -eq 0 ] || die "成果物检查未通过, 请先执行 ./build_qemu.sh -b"

    if [ "$verify" -eq 1 ]; then
        # 验证模式保持单发语义: panic/reboot 不重启虚拟机而是退出 QEMU, 回归不会死循环
        qemu_args=("-no-reboot" "${qemu_args[@]}")
    fi
    # 交互模式刻意不带 -no-reboot: PSCI 复位后 QEMU 完整重启虚拟机,
    # U-Boot 从 pflash 重新执行并自动引导, 与实体板 reset 行为一致;
    # (loader 预加载到 0x44000000/0x60000000 的内核与 initramfs 是热复位, RAM 内容保留)

    mkdir -p "$OUT"
    if [ "$verify" -eq 1 ]; then
        step "启动 QEMU virt 板卡 [验证模式] (跑完 VERIFY 标记自动关机, 重启即退出; 串口日志: $OUT/boot.log)"
    else
        step "启动 QEMU virt 板卡 [交互终端] (exit 重生 shell; poweroff 关机; reset 真重启; Ctrl-A x 强退)"
    fi
    set +e
    qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1G -nographic \
        -bios "$BUILD/uboot/u-boot.bin" \
        -device loader,file="$BUILD/kernel/arch/arm64/boot/Image",addr=0x44000000,force-raw=on \
        -device loader,file="$cpio",addr=0x60000000,force-raw=on \
        "${qemu_args[@]}" 2>&1 | tee "$OUT/boot.log"
    local rc=$?
    set -e
    if [ "$verify" -eq 1 ]; then
        if grep -q 'ALL-ARTIFACTS-VERIFIED' "$OUT/boot.log" \
            && grep -q 'reboot: Power down' "$OUT/boot.log"; then
            ok "启动验证通过(VERIFY 标记齐全), QEMU exit=$rc"
        else
            warn "未检测到完整验证标记, QEMU exit=$rc, 完整串口日志见 $OUT/boot.log"
        fi
    else
        ok "串口终端已退出 (exit=$rc); 再次进入: ./build_qemu.sh -r"
    fi
}

do_clean() {
    step "删除构建产物"
    if [ -d "$BUILD" ]; then
        echo "  rm -rf $BUILD ($(du -sh "$BUILD" 2>/dev/null | cut -f1))"
        rm -rf "$BUILD"
    else
        echo "  (无 $BUILD)"
    fi
    if [ -d "$OUT" ]; then
        echo "  rm -rf $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
        rm -rf "$OUT"
    else
        echo "  (无 $OUT)"
    fi
    ok "已清理, 重新构建请执行 ./build_qemu.sh -b"
}

case "${1:-}" in
    -b) shift; do_build "$@" ;;
    -r) shift; do_run "$@" ;;
    -c) shift; do_clean "$@" ;;
    -h|--help) usage ;;
    *) usage; [ $# -eq 0 ] && exit 0 || exit 1 ;;
esac
