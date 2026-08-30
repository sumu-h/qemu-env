<!-- more -->

> 使用 manifest 仓库 <https://cnb.cool/sumu.h/qemu/manifests> 拉取 U-Boot / Linux kernel / busybox 源码，编译出三件成果物（u-boot v2026.07 / kernel 7.2.2 / busybox 1.38.0），在 QEMU `virt` 虚拟板卡上完成全链路启动验证，并记录一次内核 init ENOEXEC 的排查过程。

## 一、 环境准备

### 1. 要安装哪些内容？
本仓库 Dockerfile 构建的开发镜像已预置全部依赖：

| 组件 | 版本/路径 |
|------|-----------|
| repo launcher | 2.65（`/usr/local/bin/repo`） |
| 交叉工具链 | `aarch64-linux-musl-gcc`（GCC 11.2.1），位于 `/opt/musl-cross/aarch64-linux-musl-cross/bin`（已加入 PATH） |
| QEMU | 6.2.0（`qemu-system-aarch64`） |
| 编译依赖 | bison/flex、libssl-dev、libelf-dev、bc/cpio、dtc、u-boot-tools 等 |

### 2. 拉取源码（repo）

#### 2.1 manifest 清单说明

manifest 仓库内含两个清单文件：

- `remote.xml` —— 定义 remote `origin = https://cnb.cool/sumu.h/qemu/`，被其余清单 include；
- `qemu_env_latest.xml` —— 跟踪各仓库 main 分支最新版。

> 注意：repo 默认找 `default.xml`，本 manifest 仓库没有该文件，必须用 `-m` 显式指定清单。

#### 2.2 repo init 与 repo sync

```bash
git config --global user.name  "sumu"            # repo 要求 git 身份
git config --global user.email "sumu@example.com"

mkdir -p /workspace/src && cd /workspace/src
repo init -u https://cnb.cool/sumu.h/qemu/manifests \
     -m qemu_env_latest.xml --no-repo-verify --depth=1
repo sync -c -j8 --fail-fast
```

## 二、 编译成果物

按 busybox → U-Boot → kernel 的顺序构建，配置统一用源码树里的 `qemu_defconfig`；整套流程也可用 `build_qemu.sh -b / -r / -c` 一键完成。

### 1. busybox 静态编译与 initramfs 制作

#### 1.1 编译

```bash
mkdir -p /workspace/build/busybox
make -C /workspace/src/busybox O=/workspace/build/busybox qemu_defconfig
make -C /workspace/src/busybox O=/workspace/build/busybox -j32
```

产物 `build/busybox/busybox`：ELF 64-bit ARM aarch64，static-pie，1.27 MB。

#### 1.2 安装到 rootfs 并制作骨架

```bash
make -C /workspace/src/busybox O=/workspace/build/busybox \
     CONFIG_PREFIX=/workspace/build/rootfs install

cd /workspace/build/rootfs
mkdir -p dev proc sys tmp etc root mnt run
mknod -m 622 dev/console c 5 1     # initramfs 阶段内核打开 /dev/console 需要静态节点
mknod -m 666 dev/null    c 1 3
```

#### 1.3 init 脚本

init 脚本见 [`build/rootfs/init`](../build/rootfs/init)，由内核通过 `rdinit=/init` 直接执行：

```sh
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
```

交互模式（`-r`）的 `/init` 则在挂载后 `exec /sbin/init`，由 `/etc/inittab` 在串口常驻 shell。

#### 1.4 cpio 打包

```bash
cd /workspace/build/rootfs
find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9 \
    > /workspace/build/rootfs.cpio.gz
truncate -s 4M /workspace/build/rootfs.cpio.gz   # 零填充到固定 0x400000
```

产物固定 4194304 字节 = 0x400000。

#### 1.5 busybox 必须静态编译吗？

不是"必须"，但对 initramfs 方案强烈建议静态。决定性因素是**动态链接的依赖链要自己补齐**：

- **静态（本文方案）**：单个 `bin/busybox` 自包含，放进 cpio 就能跑；musl 工具链对静态链接支持完善，没有 glibc 静态化的 NSS 类坑；
- **动态**：cpio 里必须额外附带 ELF 解释器与 libc。musl 只需一个文件——把工具链的 `aarch64-linux-musl/lib/libc.so` 拷入 rootfs `/lib/libc.so`，再建软链 `/lib/ld-musl-aarch64.so.1 -> /lib/libc.so` 即可（musl 的加载器与 libc 本就是同一个文件）；glibc 则要 `ld-linux-aarch64.so.1` + `libc.so.6` 等一串，还得用 `readelf -d` 逐个核对 NEEDED 依赖；
- **什么时候动态合适**：切换到真实 rootfs（如 virtio-blk 挂 ext4 根分区）后，库都在根分区里，动态 busybox 更省体积也完全正常。

另注意：静态与否与第四节的 ENOEXEC 事故无关——那是架构错误（x86-64 误编）。静态链接解决"少带文件"，`CONFIG_CROSS_COMPILER_PREFIX` 固化解决"编对架构"。

### 2. U-Boot

#### 2.1 自动引导方案

QEMU `virt` 板卡上由 U-Boot 自动引导内核的方案分三步：

1. QEMU 通过 `-device loader` 在上电前把 `Image`（0x44000000）和 `rootfs.cpio.gz`（0x60000000）预放进内存；
2. U-Boot 从 pflash（`-bios`）启动，执行烧入默认环境的 `bootcmd`；
3. QEMU 生成的设备树位于 `$fdt_addr = 0x40000000`（见 u-boot 源码 `board/emulation/qemu-arm/qemu-arm.env`）。

因此把 `bootargs` 和 `booti` 命令烘焙进 U-Boot 默认环境，上电即可全自动引导（initrd 尺寸固定 `0x400000`，对应 1.4 的零填充）：

```sh
# configs/qemu_defconfig（在 qemu_arm64_defconfig 基础上烘焙）
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="setenv bootargs console=ttyAMA0,115200 rdinit=/init; booti 0x44000000 0x60000000:0x400000 ${fdt_addr}"
```

#### 2.2 编译步骤

```bash
mkdir -p /workspace/build/uboot
make -C /workspace/src/u-boot O=/workspace/build/uboot CROSS_COMPILE=aarch64-linux-musl- qemu_defconfig
make -C /workspace/src/u-boot O=/workspace/build/uboot CROSS_COMPILE=aarch64-linux-musl- -j8
```

产物 `build/uboot/u-boot.bin`（1.5 MB）。

### 3. kernel

```bash
mkdir -p /workspace/build/kernel
make -C /workspace/src/kernel O=/workspace/build/kernel ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-musl- qemu_defconfig
make -C /workspace/src/kernel O=/workspace/build/kernel ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-musl- -j32
```

产物 `build/kernel/arch/arm64/boot/Image`（50.9 MB，defconfig 全量构建含约两千个模块）。

## 三、 QEMU virt 启动验证

### 1. 启动命令

```bash
qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1G -no-reboot -nographic \
  -bios u-boot.bin \
  -device loader,file=Image,addr=0x44000000,force-raw=on \
  -device loader,file=rootfs.cpio.gz,addr=0x60000000,force-raw=on
```

以上为 `-r test`（验证模式）的等价命令；交互模式 `-r` 去掉 `-no-reboot`、加载 `rootfs-shell.cpio.gz`。

### 2. 串口日志关键节点

完整日志见 [`out/boot.log`](../out/boot.log)：

```
U-Boot 2026.07-gf9b37620606a (Aug 29 2026 - 15:19:06 +0000)
DRAM:  1 GiB
Flash: 64 MiB
Hit any key to stop autoboot: 0
## Flattened Device Tree blob at 40000000
   Loading Ramdisk to 7d471000, end 7d528cdf ... OK
Starting kernel ...

[    0.000000] Linux version 7.2.2-gf19b37cfb688 ... (aarch64-linux-musl-gcc (GCC) 11.2.1 ...)
[    0.609367] Run /init as init process
VERIFY-BUSYBOX: userspace is alive, PID 1 = init
VERIFY-BUSYBOX: BusyBox v1.38.0 (2026-08-29 15:18:20 Asia) multi-call binary.
VERIFY-KERNEL:  Linux (none) 7.2.2-... aarch64 GNU/Linux
ALL-ARTIFACTS-VERIFIED: u-boot -> kernel 7.2.2 -> busybox 1.38.0
[    0.740203] reboot: Power down
```

### 3. 验证标记说明

init 内的验证标记逐项确认了三件成果物：

| 标记 | 验证内容 |
|------|----------|
| U-Boot banner / `Starting kernel ...` | U-Boot 正常运行并完成引导 |
| `Linux version 7.2.2` + `uname -a` | 内核在 virt 板卡上正常启动 |
| `PID 1 = init`、BusyBox 横幅、`ls /` | busybox 用户态正常执行 |

`poweroff -f` 触发 PSCI 关机，QEMU 以 exit 0 干净退出。

## 四、 常见问题

### 1. 内核 panic No working init found（error -8）

#### 1.1 现象

三件成果物首次联调，U-Boot 与内核阶段全部正常，但 initramfs 里所有 init 候选都无法执行：

```
[    0.246024] Unpacking initramfs...
[    0.605194] Run /init as init process
[    0.606796] Failed to execute /init (error -8)          ← -8 = ENOEXEC
[    0.606962] Run /sbin/init as init process
[    0.607516] Starting init: /sbin/init exists but couldn't execute it (error -8)
[    0.608203] Run /bin/sh as init process
[    0.608567] Starting init: /bin/sh exists but couldn't execute it (error -8)
[    0.608882] Kernel panic - not syncing: No working init found.
```

文件存在、可执行位正常，但 execve 全部返回 ENOEXEC（没有 binfmt 处理器接受该文件）。

#### 1.2 排查过程：逐项排除，最后靠指纹锁定

##### 1.2.1 脚本格式

`/init` 是 `#!/bin/sh` 脚本，先排除编码 / 换行问题：

```bash
head -c 32 rootfs/init | od -c
# #   !   /   b   i   n   /   s  h  \n ...   ← shebang 干净，无 BOM/CRLF
```

##### 1.2.2 内核配置

arm64 defconfig 的 binfmt 支持齐全：

```
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
```

##### 1.2.3 initramfs 内容

cpio 归档完整，`bin/sh -> busybox`、`sbin/init` 均存在且权限为 755。

三条都正常，于是换思路：把 rootfs 里的 busybox 直接在主机上用 qemu-user 跑一下（最小化复现，绕开内核）。

##### 1.2.4 最小化复现与指纹比对

```bash
zcat rootfs.cpio.gz | cpio -idm --quiet -D /tmp/rfstest
qemu-aarch64 /tmp/rfstest/bin/busybox echo HELLO
# qemu-aarch64: ./bin/busybox: Invalid ELF image for this architecture   ← 破案线索！
```

指纹比对：各副本 md5 一致，但 readelf 显示架构不对：

```bash
md5sum build/busybox/busybox build/rootfs/bin/busybox out/busybox   # 四处完全一致
readelf -h /tmp/rfstest/bin/busybox | grep Machine
# Machine:  Advanced Micro Devices X86-64        ← busybox 是 x86-64 的！
file    /tmp/rfstest/bin/busybox
# ELF 64-bit LSB executable, x86-64, ..., statically linked, for GNU/Linux 3.2.0
```

#### 1.3 根因

时间线还原：

1. 带 `CROSS_COMPILE=aarch64-linux-musl-` 编译，产物确认为 ARM aarch64（当时 `file` / `readelf` 都验过）；
2. 执行 `make ... CONFIG_PREFIX=... install` 时漏掉了 `CROSS_COMPILE` —— 该命令触发了全量重编，没有交叉前缀时使用主机 gcc（x86-64 + glibc），新二进制覆盖了 build 目录的 ARM 版本并装入 rootfs；
3. x86-64 ELF 在 arm64 内核上没有任何 binfmt 处理器匹配 → ENOEXEC；
4. `/init` 是 `#!/bin/sh` 脚本，内核解析 shebang 后去执行 `/bin/sh`（symlink → busybox），同样 ENOEXEC，错误逐级向上传递，最终所有 init 候选全灭、内核 panic。

日志里"文件存在但 couldn't execute"与 ENOEXEC（而非 ENOENT/EACCES）的组合，正是"架构不对的可执行文件"的典型特征。

#### 1.4 修复

```bash
# 1. 清掉 x86-64 的 .o 和二进制，带交叉前缀重编
make -C /workspace/src/busybox O=/workspace/build/busybox clean
make -C /workspace/src/busybox O=/workspace/build/busybox -j32 CROSS_COMPILE=aarch64-linux-musl-
file build/busybox/busybox        # ← 每一步都验架构：ARM aarch64 ✔

# 2. install 同样带上交叉前缀（根因所在）
make -C /workspace/src/busybox O=/workspace/build/busybox \
     CROSS_COMPILE=aarch64-linux-musl- CONFIG_PREFIX=/workspace/build/rootfs install

# 3. md5 校验安装产物与编译产物一致，再重新打包
md5sum build/rootfs/bin/busybox build/busybox/busybox   # 一致 ✔
find . -print0 | cpio --null -o -H newc --owner=0:0 | gzip -9 > rootfs.cpio.gz

# 4. initramfs 尺寸变化 → 同步更新 U-Boot bootcmd 中的 initrd 大小并重编 U-Boot
#    752863 = 0xb7cdf  →  booti 0x44000000 0x60000000:0xb7cdf ${fdt_addr}
```

重新启动后 `Run /init as init process` → `VERIFY-*` 标记齐全 → `reboot: Power down`，QEMU exit 0，问题闭环。

#### 1.5 经验

- 交叉编译的每一个 make 子命令（含 install）都必须带 `CROSS_COMPILE`。busybox 的 install 可能触发重编，漏传前缀时会用主机工具链静默产出错误架构的二进制并覆盖正确产物；
- `error -8 (ENOEXEC)` + "文件存在但无法执行" = 先怀疑架构 / 格式，而不是脚本内容或内核配置；
- 排查顺序上，`od -c` 验 shebang、`grep .config` 验 binfmt、cpio 列表验内容都正常时，应尽早切到"最小化复现 + 产物指纹"（qemu-user 单跑、file/readelf/md5sum），比在内核侧继续加打印收敛快得多；
- 产物进 rootfs / 归档前做一次 `file` + md5 校验，一条命令就能把这类问题挡在烧写之前。

---
*本文档由 markdowncli 技能辅助生成*
