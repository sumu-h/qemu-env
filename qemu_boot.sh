#!/usr/bin/env bash
# =============================================================================
# qemu_boot — 一键启动镜像内置的 QEMU virt (aarch64) 虚拟板卡
#
# 启动链: U-Boot(-bios) -> 内核(loader 预加载 0x44000000) -> initramfs(0x60000000)
# 成果物由 start.sh -b 编译并拷入仓库 .qemu/, 打镜像时 COPY 进镜像 $HOME/.qemu
#
# 用法:
#   qemu_boot              交互串口终端 (exit 退出 shell 自动重生; poweroff 关机;
#                          reset 真重启; Ctrl-A x 强退 QEMU)
#   qemu_boot --test       验证模式: 自动执行 VERIFY 标记检查后关机 (无人值守冒烟测试)
#   qemu_boot [qemu参数]   其余参数原样透传给 qemu-system-aarch64 (如 -S -s 配合 gdb)
#
# 网络: 单网卡 SLIRP + hostfwd 2222->22 (dropbear 已内置, 账号 root/root)
#   docker run 加 -p 2222:2222 启动容器后, 宿主机: ssh -p 2222 root@127.0.0.1
#
# 环境变量:
#   QEMU_DIR    成果物目录, 默认 $HOME/.qemu
#   VM_SSH_FWD  hostfwd 规则, 默认 tcp::2222-:22
# =============================================================================
set -euo pipefail

QEMU_DIR="${QEMU_DIR:-$HOME/.qemu}"
UBOOT="$QEMU_DIR/u-boot.bin"
KERNEL="$QEMU_DIR/Image"
INITRAMFS_SHELL="$QEMU_DIR/rootfs-shell.cpio.gz"   # 交互终端版(默认)
INITRAMFS_TEST="$QEMU_DIR/rootfs.cpio.gz"          # 自动验证版(--test)
INITRAMFS_SIZE=$((4 * 1024 * 1024))    # 0x400000, 与 U-Boot BOOTCOMMAND 固定加载长度对应
VM_SSH_FWD="${VM_SSH_FWD:-tcp::2222-:22}"
# MAC 必须与 rootfs /etc/rc.sh 的按 MAC 配网一致, 否则 guest 网卡配不到 IP (SLIRP: 10.0.2.15)
NET_MAC_USR="52:54:00:CA:FE:02"

die() { echo -e "  ❌ $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: qemu_boot [选项] [qemu参数...]
选项:
  (无参数)  启动交互串口终端 (exit 重生 shell; poweroff 关机; Ctrl-A x 强退)
  --test    验证模式: 打印 VERIFY 标记后自动关机 (无人值守冒烟测试)
  -h        显示本帮助
其余参数原样透传给 qemu-system-aarch64 (如 -S -s 配合 gdb 远程调试)
成果物: $QEMU_DIR (默认 $HOME/.qemu), 由 build.sh 打包镜像时内置
EOF
}

main() {
    local cpio="$INITRAMFS_SHELL"
    local qemu_args=() pre_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --test) cpio="$INITRAMFS_TEST" ;;
            -h|--help) usage; return 0 ;;
            *) qemu_args+=("$1") ;;
        esac
        shift
    done

    command -v qemu-system-aarch64 >/dev/null 2>&1 \
        || die "找不到 qemu-system-aarch64 (基础镜像应已预装, 请检查镜像)"
    [ -s "$UBOOT" ] \
        || die "缺少 $UBOOT —— 镜像未内置成果物, 请在开发环境执行 ./start.sh -b && ./build.sh -b 重新打包"
    [ -s "$KERNEL" ] || die "缺少 $KERNEL"
    [ -f "$cpio" ] || die "缺少 $cpio"
    [ "$(stat -c%s "$cpio")" -eq "$INITRAMFS_SIZE" ] \
        || die "$(basename "$cpio") 尺寸不是 0x400000 (U-Boot BOOTCOMMAND 按固定长度加载), 请勿替换未填充的 initramfs"
    file -b "$KERNEL" | grep -qi 'ARM64' \
        || die "Image 架构不是 ARM64: $(file -b "$KERNEL")"

    # 验证模式保持单发语义: panic/重启即退出 QEMU, 冒烟测试不死循环
    [ "$cpio" = "$INITRAMFS_SHELL" ] || pre_args=(-no-reboot)

    if [ "$cpio" = "$INITRAMFS_SHELL" ]; then
        echo "➤  启动 QEMU virt 板卡 [交互终端] (exit 重生 shell; poweroff 关机; Ctrl-A x 强退)"
        echo "➤  SSH: ssh -p 2222 root@127.0.0.1 (密码 root; 需 docker run -p 2222:2222)"
    else
        echo "➤  启动 QEMU virt 板卡 [验证模式] (跑完 VERIFY 标记自动关机)"
    fi
    exec qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1G -nographic \
        -bios "$UBOOT" \
        -device "loader,file=$KERNEL,addr=0x44000000,force-raw=on" \
        -device "loader,file=$cpio,addr=0x60000000,force-raw=on" \
        -netdev "user,id=net0,hostfwd=$VM_SSH_FWD" \
        -device "virtio-net-pci,netdev=net0,mac=$NET_MAC_USR" \
        "${pre_args[@]}" \
        "${qemu_args[@]}"
}

main "$@"
