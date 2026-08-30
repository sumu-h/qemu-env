#!/usr/bin/env bash
# =============================================================================
# qemu_boot — 一键启动镜像内置的 QEMU virt (aarch64) 虚拟板卡
#
# 启动链: U-Boot(-bios) -> 内核(loader 预加载 0x44000000) -> initramfs(0x60000000)
# 成果物由 start.sh -b 编译并拷入仓库 .qemu/, 打镜像时 COPY 进镜像 $HOME/.qemu
#
# 用法:
#   qemu_boot              交互串口终端, 串口在 stdio (exit 退出 shell 自动重生;
#                          poweroff 关机; reset 真重启; Ctrl-A x 强退 QEMU)
#   qemu_boot --test       验证模式: 自动执行 VERIFY 标记检查后关机 (无人值守冒烟测试)
#   qemu_boot --serial-tcp [目标] [--wait]
#                          后台板卡模式: QEMU 转后台, 串口挂 TCP 供终端脚本连接
#                          (如 node terminal.mjs tcp://host:port), stdio 保持安静
#                            [目标]  省略 = 127.0.0.1:4444; 支持 [host:]port;
#                                    stop = 停止后台板卡
#                            --wait 等首个客户端连上才开始引导(wait=on), 可看到从
#                                   U-Boot 起的完整输出并打断 autoboot;
#                                   默认 wait=off 立即引导(连接晚错过开头, 回车拿 shell)
#   qemu_boot [qemu参数]   其余参数原样透传给 qemu-system-aarch64 (如 -S -s 配合 gdb)
#
# 网络: 单网卡 SLIRP + hostfwd 2222->22 (dropbear 已内置, 账号 root/root)
#   docker run 加 -p 2222:2222 启动容器后, 宿主机: ssh -p 2222 root@127.0.0.1
#   --serial-tcp 供容器外终端连接时, 目标写 0.0.0.0:port 并 docker run -p 发布端口
#
# 环境变量:
#   QEMU_DIR    成果物目录, 默认 $HOME/.qemu
#   VM_SSH_FWD  hostfwd 规则, 默认 tcp::2222-:22
#
# 后台板卡模式文件 (位于 $QEMU_DIR):
#   qemu.pid               QEMU 进程号 (--serial-tcp stop 用)
#   boot.log               串口全量日志(含上电阶段与双向流量), tail -f 观察打印
#   qemu-serial-tcp.log    QEMU 自身 stdout/stderr
# =============================================================================
set -euo pipefail

QEMU_DIR="${QEMU_DIR:-$HOME/.qemu}"
UBOOT="$QEMU_DIR/u-boot.bin"
KERNEL="$QEMU_DIR/Image"
INITRAMFS_SHELL="$QEMU_DIR/rootfs-shell.cpio.gz"   # 交互终端版(默认)
INITRAMFS_TEST="$QEMU_DIR/rootfs.cpio.gz"          # 自动验证版(--test)
INITRAMFS_SIZE=$((4 * 1024 * 1024))    # 0x400000, 与 U-Boot BOOTCOMMAND 固定加载长度对应
VM_SSH_FWD="${VM_SSH_FWD:-tcp::2222-:22}"
PIDFILE="$QEMU_DIR/qemu.pid"
SERIAL_TCP_DEFAULT="127.0.0.1:4444"
# MAC 必须与 rootfs /etc/rc.sh 的按 MAC 配网一致, 否则 guest 网卡配不到 IP (SLIRP: 10.0.2.15)
NET_MAC_USR="52:54:00:CA:FE:02"

die() { echo -e "  ❌ $*" >&2; exit 1; }

usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

# 停止 --serial-tcp 启动的后台板卡 (pidfile 不存在或进程已退出则幂等提示)
stop_serial_tcp() {
    local pid
    if [ -s "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.3
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
                echo "✅ 后台板卡已强制终止 (pid $pid)"
            else
                echo "✅ 后台板卡已停止 (pid $pid)"
            fi
        else
            echo "后台板卡未在运行 (pid $pid 已退出)"
        fi
        rm -f "$PIDFILE"
    else
        echo "后台板卡未在运行 (无 $PIDFILE)"
    fi
}

main() {
    local cpio="$INITRAMFS_SHELL" serial_tcp="" wait_on=0
    local qemu_args=() pre_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --test) cpio="$INITRAMFS_TEST" ;;
            --serial-tcp)
                shift
                case "${1:-}" in
                    stop)   serial_tcp="stop" ;;
                    [0-9]*) serial_tcp="$1" ;;
                    *)      serial_tcp="$SERIAL_TCP_DEFAULT"; continue ;;  # 不带目标: 默认端口, 该参数留给后续解析
                esac
                ;;
            --wait) wait_on=1 ;;
            -h|--help) usage; return 0 ;;
            *) qemu_args+=("$1") ;;
        esac
        shift
    done

    if [ "$serial_tcp" = "stop" ]; then
        stop_serial_tcp
        return 0
    fi
    if [ -n "$serial_tcp" ]; then
        case "$serial_tcp" in *:*) ;; *) serial_tcp="127.0.0.1:$serial_tcp" ;; esac
    fi
    if [ "$wait_on" -eq 1 ] && [ -z "$serial_tcp" ]; then
        echo "⚠️  --wait 仅在 --serial-tcp 模式生效, 已忽略" >&2
        wait_on=0
    fi

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

    local -a qemu_cmd=(
        qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1G
        -bios "$UBOOT"
        -device "loader,file=$KERNEL,addr=0x44000000,force-raw=on"
        -device "loader,file=$cpio,addr=0x60000000,force-raw=on"
        -netdev "user,id=net0,hostfwd=$VM_SSH_FWD"
        -device "virtio-net-pci,netdev=net0,mac=$NET_MAC_USR"
        "${pre_args[@]}" "${qemu_args[@]}"
    )

    if [ -n "$serial_tcp" ]; then
        local wait_opt="wait=off"
        [ "$wait_on" -eq 1 ] && wait_opt="wait=on"
        # -display none + -monitor none: stdio 完全安静, 串口独占挂 TCP 并全量落盘
        qemu_cmd+=(
            -display none
            -serial "tcp:$serial_tcp,server=on,$wait_opt,logfile=$QEMU_DIR/boot.log"
            -monitor none
        )
    else
        qemu_cmd+=(-nographic)
    fi

    if [ -n "$serial_tcp" ]; then
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            die "后台板卡已在运行 (pid $(cat "$PIDFILE")); 停止: qemu_boot --serial-tcp stop"
        fi
        rm -f "$PIDFILE"
        : > "$QEMU_DIR/boot.log"    # 每次启动重开日志, 避免混入上一轮内容
        nohup "${qemu_cmd[@]}" </dev/null >> "$QEMU_DIR/qemu-serial-tcp.log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PIDFILE"
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PIDFILE"
            die "QEMU 启动失败, 见 $QEMU_DIR/qemu-serial-tcp.log"
        fi
        echo "✅ 后台板卡已启动 (pid $pid)"
        echo "   串口:   tcp://$serial_tcp -> node terminal.mjs tcp://$serial_tcp"
        if [ "$wait_on" -eq 1 ]; then
            echo "   引导:   等待首个连接 (wait=on), 连上即见 U-Boot 起的完整输出"
        else
            echo "   引导:   已自行引导 (wait=off); 连接晚错过开头, 回车即可拿 shell"
        fi
        echo "   观察打印: tail -f $QEMU_DIR/boot.log"
        echo "   SSH:    ssh -p 2222 root@127.0.0.1 (密码 root)"
        echo "   停止:   qemu_boot --serial-tcp stop (或在串口内 poweroff)"
        return 0
    fi

    if [ "$cpio" = "$INITRAMFS_SHELL" ]; then
        echo "➤  启动 QEMU virt 板卡 [交互终端] (exit 重生 shell; poweroff 关机; Ctrl-A x 强退)"
        echo "➤  SSH: ssh -p 2222 root@127.0.0.1 (密码 root; 需 docker run -p 2222:2222)"
    else
        echo "➤  启动 QEMU virt 板卡 [验证模式] (跑完 VERIFY 标记自动关机)"
    fi
    exec "${qemu_cmd[@]}"
}

main "$@"
