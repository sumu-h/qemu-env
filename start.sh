#!/usr/bin/env bash
set -euo pipefail

DEV_DIR="$HOME/qemu_dev"
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

main() {
    setup_git
    mkdir -p "$DEV_DIR"
    cd "$DEV_DIR"
    init_repo
    sync_code
    command -v code >/dev/null && code "$DEV_DIR" || true
}

main
