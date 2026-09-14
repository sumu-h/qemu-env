## 一、 项目简介

本项目基于 QEMU 提供的用户模式模拟环境，用于在 x86 主机上运行不同架构的 Linux 应用程序。通过集成 musl 交叉工具链，支持全静态链接，实现跨平台开发和测试。

## 二、 musl 简介

**musl**（发音同英文 "mussel"，即"贻贝"）是一个基于 **MIT 许可证** 的标准 C 库实现，面向 Linux 系统调用 API，适用于广泛的部署环境。

musl 天然适合做 **全静态链接**：编出的二进制自包含、不依赖目标架构根文件系统，可直接在 `qemu-user` 下运行，非常适合内核 / 嵌入式开发中构建静态用户态测试程序。本镜像通过预编译 musl 交叉工具链（`aarch64-linux-musl-gcc`、`riscv64-linux-musl-gcc`）获得这一便利。

### 1. GitHub 仓库与下载地址

| 项目 | 地址 |
|------|------|
| 官网 | https://musl.libc.org/ |
| 官方源码仓库（自托管 git） | https://git.musl-libc.org/cgit/musl |
| GitHub 源码镜像 | https://github.com/kraj/musl |
| 预编译工具链站 musl.cc | https://musl.cc/ |
| GitHub 工具链镜像（本镜像所用下载源） | https://github.com/musl-cc/musl.cc |
| 工具链下载（GitHub Releases） | https://github.com/musl-cc/musl.cc/releases |

## 三、 QEMU 虚拟板卡

镜像内置一键启动脚本 [`qemu_boot.sh`](qemu_boot.sh)（安装为 `qemu_boot` 命令），把镜像中的 U-Boot、内核与 initramfs 组装成一块 aarch64 虚拟板卡，免去每次手写一长串 qemu 命令行。完整参数说明见 `qemu_boot -h`。

### 1. 启动链与前置条件

启动链为 U-Boot → 内核 → initramfs，三段产物都由 qemu 预先安置到固定位置：

| 阶段 | 加载方式 | 地址 / 说明 |
|------|----------|-------------|
| U-Boot | `-bios` 当作 pflash 加载 | 引导起点，负责搬运并跳转内核 |
| 内核 | `loader` 设备预加载 | `0x44000000` |
| initramfs | `loader` 设备预加载 | `0x60000000`，内核挂载为根文件系统并执行 `/init` |

前置条件：镜像中需已内置上述成果物，位于 `$HOME/.qemu`（可用环境变量 `QEMU_DIR` 覆盖）：

- `u-boot.bin`：U-Boot
- `Image`：内核
- `rootfs-shell.cpio.gz`：交互版 initramfs，默认加载
- `rootfs.cpio.gz`：验证版 initramfs，`--test` 时加载

开发环境先执行 [`start.sh`](start.sh) `-b` 编译并把成果物拷入仓库 `.qemu/`，再执行 [`build.sh`](build.sh) `-b` 打包进镜像；`qemu_boot` 发现文件缺失会直接报错并提示重新打包。其中 initramfs 尺寸必须为 `0x400000`（4 MiB），因为 U-Boot 侧的 BOOTCOMMAND 按固定长度加载。

### 2. 三种运行方式

| 运行方式 | 命令 | 用途 |
|----------|------|------|
| 交互终端（默认） | `qemu_boot` | 当前终端即板卡串口，适合手工调试 |
| 冒烟测试 | `qemu_boot --test` | 换用验证版 initramfs，跑完 VERIFY 标记检查后自动关机，适合 CI |
| 后台板卡 | `qemu_boot --serial-tcp [目标] [--wait]` | QEMU 转后台，串口挂到 TCP，供终端脚本或容器外连接 |

#### 2.1 交互终端

不带选项即进入交互串口终端，shell 内常用操作：

- `exit`：退出 shell，init 会自动重生一个新 shell
- `poweroff`：关机，QEMU 随之退出
- `reset`：真重启，重新走一遍 U-Boot
- `Ctrl-A x`：强制退出 QEMU，终端卡死时用

#### 2.2 冒烟测试

`--test` 除切换 initramfs 外还会加上 `-no-reboot`，使 panic 或重启即退出 QEMU，避免无人值守测试陷入死循环。该模式可与后台板卡组合，在后台跑测试：`qemu_boot --test --serial-tcp`。

#### 2.3 后台板卡与 TCP 串口

`--serial-tcp` 让 QEMU 转后台运行，进程号写入 `qemu.pid`，串口挂到 TCP，本机 stdio 保持安静，便于终端脚本接管。目标参数取值：

- 省略：`127.0.0.1:4444`
- 仅端口：`127.0.0.1:<端口>`
- `主机:端口`：如 `0.0.0.0:4444`，容器外连接需 `docker run -p` 发布该端口
- `stop`：停止后台板卡，读 `qemu.pid` 杀进程，幂等

`--wait` 让 qemu 等第一个客户端连上才开始引导（`wait=on`），可看到从 U-Boot 起的完整输出，也能按任意键打断 autoboot；默认不等（`wait=off`）立即引导，连接晚就错过开头，但回车即可拿 shell。前台连接示例：`node terminal.mjs tcp://127.0.0.1:4444`。

其余参数原样透传给 `qemu-system-aarch64`，例如 `qemu_boot -S -s` 可配合 gdb 在 `localhost:1234` 远程调试。

### 3. SSH 远程登录

#### 3.1 网络与端口转发

- guest 单网卡 SLIRP，MAC 固定为 `52:54:00:CA:FE:02`，因此 guest 内地址固定为 `10.0.2.15`；该 MAC 必须与 guest 内 `/etc/rc.sh` 的按 MAC 配网保持一致，否则网卡配不到 IP。

- qemu 侧按 `VM_SSH_FWD`（默认 `tcp::2222-:22`）把容器上的 `2222` 端口转发到 guest 的 `22` 端口，guest 内由 dropbear 提供 sshd，用户名与密码均为 `root`。

- SSH 与串口是两条互不影响的通道：串口看内核启动全过程，SSH 用来敲命令和传文件。SSH 固定走 `2222`，与 `--serial-tcp` 的 `4444` 无关，三种运行方式下都能连。

#### 3.2 连接方法

（1）qemu 跑在容器里，`2222` 是容器内的端口，容器外访问必须先发布端口：`docker run -it -p 2222:2222 <镜像>`，缺这个 `-p` 就会 `Connection refused`。

（2）在容器内直接连：`ssh -p 2222 root@127.0.0.1`。

（3）从宿主机或其他机器连：`ssh -p 2222 root@<宿主机IP>`，另需宿主机防火墙放行。

需等内核起来、`/etc/rc.sh` 配好网卡、dropbear 启动之后才能连上；开机头几秒连接被拒属正常，可看串口输出确认是否已进 shell。

#### 3.3 文件传输

dropbear 通常不带 `sftp-server`，而新版本 openssh 的 `scp` 默认改用 sftp 协议，因此需加 `-O` 回退老协议：

```bash
scp -O -P 2222 <文件> root@127.0.0.1:/root/
```

#### 3.4 端口调整与关闭

`VM_SSH_FWD` 控制端口转发规则，默认 `tcp::2222-:22`：

- `VM_SSH_FWD=tcp::2223-:22 qemu_boot`：换用 `2223`，适用于宿主机 `2222` 被占用
- `VM_SSH_FWD= qemu_boot`：置空则不转发端口，关闭 SSH 入口，网卡仍保持可用

#### 3.5 连不上时排查

（1）板卡在跑吗：`pgrep -af qemu-system-aarch64`。

（2）端口发布了吗：`docker run` 是否带 `-p 2222:2222`。

（3）guest 就绪吗：串口里 dropbear 是否已启动；后台模式可 `tail -f $QEMU_DIR/boot.log`。

### 4. 文件与日志

后台板卡模式会在 `$QEMU_DIR`（默认 `$HOME/.qemu`）下留下运行期文件：

| 文件 | 说明 |
|------|------|
| `qemu.pid` | 后台板卡的 QEMU 进程号，`--serial-tcp stop` 使用 |
| `boot.log` | 串口全量日志，含上电阶段与双向流量，`tail -f` 观察打印 |
| `qemu-serial-tcp.log` | QEMU 自身 stdout / stderr |

---
*本文档由 markdowncli 技能辅助生成*
