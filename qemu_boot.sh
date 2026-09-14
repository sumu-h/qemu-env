#!/usr/bin/env bash
# =============================================================================
# qemu_boot — 一键启动镜像内置的 QEMU virt (aarch64) 虚拟板卡
#
# 把镜像里预置的 U-Boot / 内核 / initramfs 组装成一块可直接操作的 aarch64
# 虚拟板卡, 免去每次手写一长串 qemu 命令行。启动链:
#
#     U-Boot (以 pflash -bios 加载)
#       └─ U-Boot 从固定地址搬运并跳转内核 (loader 预加载 0x44000000)
#            └─ 内核把 initramfs 当根文件系统挂载 (0x60000000) 并启动 /init
#
# 内核与 initramfs 都靠 loader 设备直接落到内存固定地址, 所以 U-Boot 不需要
# 去碰任何存储; initramfs 尺寸也被 U-Boot 侧的 BOOTCOMMAND 固定为 0x400000,
# 换镜像时必须保持该长度 (见下方校验)。
#
# 成果物来源: 开发环境 `./start.sh -b` 编译 -> 拷进仓库 .qemu/ -> 打镜像时由
# Dockerfile COPY 到镜像内 $HOME/.qemu。文件清单与完整用法见 `qemu_boot -h`。
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
    cat <<'EOF'
qemu_boot — 启动镜像内置的 QEMU virt (aarch64) 虚拟板卡

用法:
  qemu_boot [选项] [qemu参数...]

  U-Boot(-bios) -> 内核(loader 预加载 0x44000000) -> initramfs(0x60000000)
  不带选项即进入交互串口终端; 其余参数原样透传给 qemu-system-aarch64。

三种用法 (按需选一种, 也可组合 --test):
  ┌─ 1. 交互终端 (默认)
  │    qemu_boot
  │    当前终端即板卡串口, shell 内可用:
  │        exit        退出 shell, init 会自动重生一个新 shell
  │        poweroff    关机, QEMU 随之退出
  │        reset       真重启, 重新走一遍 U-Boot
  │        Ctrl-A x    强制退出 QEMU (终端卡死时用)
  │
  ├─ 2. 无人值守冒烟测试
  │    qemu_boot --test
  │    换用验证版 initramfs, 跑完 VERIFY 标记检查后自动关机退出, 适合 CI。
  │    该模式 panic 不再重启 (-no-reboot), 避免测试死循环。可与用法 3 组合,
  │    在后台跑测试 (qemu_boot --test --serial-tcp)。
  │
  └─ 3. 后台板卡 + TCP 串口 (供终端脚本 / 容器外连接)
       qemu_boot --serial-tcp [目标] [--wait]
       QEMU 转后台运行 (写 qemu.pid), 串口挂到 TCP, 本机 stdio 保持安静。
         [目标] 省略       -> 127.0.0.1:4444
                仅端口     -> 127.0.0.1:<端口>
                主机:端口  -> 如 0.0.0.0:4444, 需 docker run -p 发布该端口
                stop       -> 停止后台板卡 (读 qemu.pid 杀进程), 幂等
         --wait  等第一个客户端连上才开始引导 (QEMU wait=on): 能看到从 U-Boot
                起的完整输出, 也能按任意键打断 autoboot。默认不等 (wait=off)
                立即引导, 连接晚就错过开头, 但回车即拿 shell。
       连接: node terminal.mjs tcp://127.0.0.1:4444

选项:
  --test               使用验证版 initramfs 并 -no-reboot (见用法 2)
  --serial-tcp [目标]  转后台并开 TCP 串口 (见用法 3), 目标省略时用 127.0.0.1:4444
  --wait               仅配合 --serial-tcp 生效: 等首个连接再引导;
                       单独使用时告警并忽略
  -h, --help           显示本帮助
  其他参数             原样透传给 qemu-system-aarch64, 如 -S -s 配合 gdb 调试

环境变量:
  QEMU_DIR     成果物目录, 默认 $HOME/.qemu
  VM_SSH_FWD   SSH 端口转发规则, 默认 tcp::2222-:22; 置空则不转发 (等于关掉 SSH)

网络与 SSH 远程登录:
  网卡: guest 单网卡 SLIRP, MAC 固定 52:54:00:CA:FE:02 -> guest 内地址固定为
        10.0.2.15。该 MAC 必须与 guest 内 /etc/rc.sh 的按 MAC 配网一致, 否则网卡
        配不到 IP; qemu 侧按 VM_SSH_FWD 把容器 2222 转发到 guest 的 22 端口,
        guest 内由 dropbear 提供 sshd, 用户名与密码均为 root。

  SSH 与串口是两条互不影响的通道, 可同时用: 串口看内核启动全过程, SSH 用来敲
  命令和传文件。SSH 固定走 2222, 与 --serial-tcp 的 4444 无关, 三种运行方式下
  都能连 (板卡在跑就行, 不必非得是后台模式)。

  qemu 跑在容器里, 所以 2222 是"容器内"的端口, 容器外想连必须先把端口发布出来:
      docker run -it -p 2222:2222 ... <镜像>   # 缺这个 -p 就会 Connection refused
      从宿主机/其他机器: ssh -p 2222 root@<宿主机IP>   # 另需宿主机防火墙放行
      在容器内自己连:    ssh -p 2222 root@127.0.0.1

  时机: 要等内核起来、rc.sh 配好网卡、dropbear 启动之后才能连上; 开机头几秒
        连接被拒属正常, 可看串口输出确认是否已进 shell。

  传文件 (dropbear 通常不带 sftp-server, scp 需加 -O 回退老协议):
      scp -O -P 2222 <文件> root@127.0.0.1:/root/

  改端口 / 关掉 SSH:
      VM_SSH_FWD=tcp::2223-:22 qemu_boot    # 宿主机 2222 被占用时换用 2223
      VM_SSH_FWD= qemu_boot                 # 空值 = 不做端口转发

  连不上时依次排查:
      1) 板卡在跑吗    pgrep -af qemu-system-aarch64
      2) 端口发布了吗  docker run 是否带 -p 2222:2222
      3) guest 就绪吗  串口里 dropbear 是否已启动
                       (后台模式: tail -f $QEMU_DIR/boot.log)

文件 (均在 $QEMU_DIR, 缺任一必需文件脚本会报错并提示重新打包):
  u-boot.bin            U-Boot, 以 pflash (-bios) 加载
  Image                 内核, loader 预加载到 0x44000000
  rootfs-shell.cpio.gz  交互版 initramfs (默认加载, 必须是 0x400000 字节)
  rootfs.cpio.gz        验证版 initramfs (--test)
  qemu.pid              后台板卡 pid (--serial-tcp stop 用)
  boot.log              后台板卡的串口全量日志, tail -f 观察
  qemu-serial-tcp.log   后台板卡 QEMU 自身 stdout/stderr

示例:
  # 启动板卡
  qemu_boot                             # 交互终端 (最常用)
  qemu_boot --test                      # 冒烟测试, 跑完自动关机
  qemu_boot --serial-tcp --wait         # 后台板卡, 等连上再引导
  qemu_boot --serial-tcp 0.0.0.0:4444   # 后台板卡, 串口端口对外
  qemu_boot --serial-tcp stop           # 停止后台板卡
  qemu_boot -S -s                       # 交互 + gdb 远程调试 (localhost:1234)

  # SSH 登录 guest (先发布 2222, 再等板卡起来)
  docker run -it -p 2222:2222 <镜像>     # 容器启动时发布 SSH 端口
  ssh -p 2222 root@127.0.0.1            # 密码 root
  VM_SSH_FWD=tcp::2223-:22 qemu_boot    # 2222 被占用时换个端口
EOF
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

    # 前置校验: 成果物缺失/尺寸/架构不符时, 在这里给出可操作的提示,
    # 否则要等 qemu 起来后在 U-Boot 或内核里看到一堆难懂的报错
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

    # 串口落点二选一: 后台板卡模式独占 TCP (并全量落盘), 其余都把串口接在当前终端上
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
        echo "   SSH:    ssh -p 2222 root@127.0.0.1 (密码 root; 与串口 4444 无关)"
        echo "           容器内直接连; 宿主机/其他机器需 docker run -p 2222:2222 并等 guest 就绪"
        echo "   停止:   qemu_boot --serial-tcp stop (或在串口内 poweroff)"
        return 0
    fi

    if [ "$cpio" = "$INITRAMFS_SHELL" ]; then
        echo "➤  启动 QEMU virt 板卡 [交互终端] (exit 重生 shell; poweroff 关机; Ctrl-A x 强退)"
        echo "➤  SSH: ssh -p 2222 root@127.0.0.1 (密码 root; 宿主机需 docker run -p 2222:2222)"
    else
        echo "➤  启动 QEMU virt 板卡 [验证模式] (跑完 VERIFY 标记自动关机)"
    fi
    exec "${qemu_cmd[@]}"
}

main "$@"
