#!/usr/bin/env bash
set -euo pipefail

DIR="$HOME/qemu_dev"

step() {
    echo -e "\e[96m➤  $@\e[0m"
}

setup_git() {
    step "设置git信息..."
    git config --global user.name "cnb"
    git config --global user.email "cnb@cnb.local"
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
    local repo_dir item
    repo_dir="$(cd "$(dirname "$0")" && pwd)"
    for item in build_qemu.sh; do
        if [ ! -e "$repo_dir/$item" ]; then
            echo "  未找到 $repo_dir/$item，跳过"
            continue
        fi
        # -f 幂等覆盖旧链接/旧副本：以仓库副本为唯一源，开发环境里只放链接
        ln -sfn "$repo_dir/$item" "$DIR/$item"
        echo "  $DIR/$item -> $repo_dir/$item"
    done
}


main() {
    setup_git
    mkdir -p "$DIR"
    cd "$DIR"
    init_repo
    sync_code
    link_assets
    command -v code >/dev/null && code "$DIR" || true
}

main
