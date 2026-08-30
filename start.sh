#!/usr/bin/env bash
set -euo pipefail

DEV_DIR="$HOME/qemu_dev"
# 必须在任何 cd 之前解析：$0 为相对路径时，cd 后再算会指向 DEV_DIR 自己
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

step() {
    echo -e "\e[96m➤  $@\e[0m"
}

setup_git() {
    step "设置git信息..."
    git config --global user.name "sumu"
    git config --global user.email "2038035593@qq.com"
}

init_repo() {
    step "初始化 .repo ..."
    [ -d .repo ] && return 0
    printf '\ny\ny\n' | repo init \
        -u https://cnb.cool/sumu.h/qemu/manifests \
        -b main \
        -m qemu_env_latest.xml \
        --repo-url https://gitee.com/sumumm/git-repo
}

sync_code() {
    step "repo 同步代码 ..."
    .repo/repo/repo sync -c -j$(nproc 2>/dev/null || echo 4)
}

link_assets() {
    step "软连接 build_qemu.sh 到开发环境 ..."
    local item
    for item in build_qemu.sh; do
        if [ ! -e "$REPO_DIR/$item" ]; then
            echo "  未找到 $REPO_DIR/$item，跳过"
            continue
        fi
        # -f 幂等覆盖旧链接/旧副本：以仓库副本为唯一源，开发环境里只放链接
        ln -sfn "$REPO_DIR/$item" "$DEV_DIR/$item"
        echo "  $DEV_DIR/$item -> $REPO_DIR/$item"
    done
}


main() {
    setup_git
    mkdir -p "$DEV_DIR"
    cd "$DEV_DIR"
    init_repo
    sync_code
    link_assets
    command -v code >/dev/null && code "$DEV_DIR" || true
}

main
