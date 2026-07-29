FROM docker.cnb.cool/sumu.k/docker-learning/ubuntu-22.04

# 安装基础编译工具
# build-essential: gcc, g++, make, libc6-dev — 内核编译必需
# libncurses-dev:  内核 make menuconfig 依赖
# python3/pip/venv: 构建脚本辅助; less/file: 常用工具; locales: 中文终端
RUN apt-get -o Acquire::Retries=5 update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        build-essential \
        python3 python3-pip python3-venv \
        libncurses-dev \
        less file \
        locales \
    && rm -rf /var/lib/apt/lists/*

# 生成中文 locale (LANG 保持 C.UTF-8 不变, 需要时自行 export LANG=zh_CN.UTF-8)
RUN sed -i '/zh_CN.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen zh_CN.UTF-8

# install vscode and extension
RUN code-server --install-extension mads-hartmann.bash-ide-vscode &&\
    code-server --install-extension llvm-vs-code-extensions.vscode-clangd &&\
    code-server --install-extension xaver.clang-format &&\
    code-server --install-extension ms-vscode.hexeditor 

# 安装 clangd 
ADD https://cnb.cool/sumu.k/my-linux/-/git/raw/main/Embedded/clangd.sh /script/clangd.sh

RUN cd /script &&\
    chmod +x *.sh && \
    bash ./clangd.sh &&\
    cd / && rm -rf /script

# 安装 QEMU 开发环境 (用户态 + 全系统模拟器 + 镜像工具 + 多架构调试)
# qemu-user:        用户态模拟器 qemu-x86_64, qemu-aarch64, qemu-riscv64, qemu-arm ...
# qemu-system-x86:  x86/x86_64 全系统模拟器
# qemu-system-arm:  ARM/AArch64 全系统模拟器
# qemu-system-misc: RISC-V 等杂项全系统模拟器
# qemu-utils:       qemu-img / qemu-nbd 磁盘镜像工具
# gdb-multiarch:    多架构调试器 (配合 qemu -g/-S 远程调试)
RUN apt-get -o Acquire::Retries=5 update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        qemu-user \
        qemu-system-x86 \
        qemu-system-arm \
        qemu-system-misc \
        qemu-utils \
        gdb-multiarch \
    && rm -rf /var/lib/apt/lists/*

# 安装 musl 交叉编译工具链 (与 os-dev 一致, U5 内核开发用)
# aarch64-linux-musl-gcc + riscv64-linux-musl-gcc, 三个下载源互为备用
RUN set -eux; \
    mkdir -p /opt/musl-cross; \
    for target in aarch64-linux-musl riscv64-linux-musl; do \
        url1="https://download.wireguard.com/qemu-test/toolchains/20211123/${target}-cross.tgz"; \
        url2="https://more.musl.cc/x86_64-linux-musl/${target}-cross.tgz"; \
        url3="http://more.musl.cc/x86_64-linux-musl/${target}-cross.tgz"; \
        echo "Downloading ${target}-cross.tgz"; \
        curl --http1.1 -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
            "$url1" -o "/tmp/${target}-cross.tgz" \
        || curl --http1.1 -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
            "$url2" -o "/tmp/${target}-cross.tgz" \
        || curl --http1.1 -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
            "$url3" -o "/tmp/${target}-cross.tgz"; \
        tar -xzf "/tmp/${target}-cross.tgz" -C /opt/musl-cross; \
        rm -f "/tmp/${target}-cross.tgz"; \
    done

ENV PATH="/opt/musl-cross/aarch64-linux-musl-cross/bin:/opt/musl-cross/riscv64-linux-musl-cross/bin:${PATH}"
