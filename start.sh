#!/usr/bin/env bash
set -euo pipefail

DEV_DIR="$HOME/qemu_dev"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

step() {
    echo -e "\e[96m➤  $@\e[0m"
}

usage() {
    cat <<'EOF'
用法: ./start.sh [选项]
选项:
  (无参数)  仅准备代码环境: repo init + sync 拉齐 ~/qemu_dev,
            并为各仓库创建与远程同名的本地分支 (避免停在游离 HEAD)
  -b        拉代码后准备 QEMU 启动成果物并拷贝到本目录 .qemu/:
            产物已存在则跳过编译直接拷贝, 缺失才编译
  -f        强制重新编译 (含 -b 行为, 忽略已有产物)
  -h        显示帮助
EOF
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

repo_bin() {
    if [ -x .repo/repo/repo ]; then
        echo ".repo/repo/repo"
    else
        echo repo
    fi
}

sync_code() {
    step "repo 同步代码 ..."
    local repo_cmd attempt jobs
    repo_cmd="$(repo_bin)"
    jobs="$(nproc 2>/dev/null || echo 4)"
    for attempt in 1 2 3; do
        if "$repo_cmd" sync -c -j"$jobs"; then
            echo "    代码同步完成"
            return 0
        fi
        [ "$attempt" -lt 3 ] || break
        echo "    ⚠ 第 $attempt 次同步失败, 5 秒后重试 ..." >&2
        sleep 5
    done
    echo "❌ repo sync 连续失败, 请检查网络后重跑 (已拉取部分不会丢失)" >&2
    exit 1
}

# repo sync 只检出 commit, 各仓库会停在游离 HEAD, 后续 commit/push 都不方便。
# 这里逐个仓库解析出它对应远程分支名, 建同名本地分支并设置上游;
# 已经在本地区分支上的仓库不动, 因此可反复执行。
ensure_branches() {
    step "为各仓库创建本地分支 ..."
    local out flag path branch n_ok=0 n_warn=0
    out="$("$(repo_bin)" forall -c '
        # 已在某个本地分支上: 不动
        git symbolic-ref -q HEAD >/dev/null 2>&1 && exit 0

        remote="${REPO_REMOTE:-origin}"
        rev="$REPO_RREV"
        branch=""

        # 1) 清单写的是分支名, 且远端存在同名分支
        if [ -n "$rev" ] && git rev-parse --verify --quiet "refs/remotes/$remote/$rev" >/dev/null 2>&1; then
            branch="$rev"
        else
            # 2) 清单写的是 SHA: 取当前 HEAD 恰好指向的远端分支 (跳过 repo 的 m/ 伪远端)
            branch="$(git for-each-ref --points-at HEAD --format="%(refname)" refs/remotes 2>/dev/null |
                      grep -v "^refs/remotes/m/" |
                      sed -n "s|^refs/remotes/[^/]*/||p" |
                      grep -vx "HEAD" | sort | head -1)"
        fi

        if [ -z "$branch" ]; then
            echo "WARN|$REPO_PATH|无法确定远程分支名 (revision=${rev:-未指定}), 保持游离"
            exit 0
        fi

        if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
            git checkout "$branch" >/dev/null 2>&1 || {
                echo "WARN|$REPO_PATH|切换到已有分支 $branch 失败"
                exit 0
            }
        else
            git checkout -b "$branch" >/dev/null 2>&1 || {
                echo "WARN|$REPO_PATH|创建分支 $branch 失败"
                exit 0
            }
            # 上游指向同名远程分支, 后续 push/pull 无需再指定
            git branch --set-upstream-to="$remote/$branch" "$branch" >/dev/null 2>&1 || true
        fi
        echo "OK|$REPO_PATH|$branch"
    ' 2>&1 || true)"

    while IFS='|' read -r flag path branch; do
        case "$flag" in
            OK)
                n_ok=$((n_ok + 1))
                echo "    $path -> $branch"
                ;;
            WARN)
                n_warn=$((n_warn + 1))
                echo "    ⚠ $path: $branch" >&2
                ;;
        esac
    done <<<"$out"

    echo "    分支就绪 $n_ok 个, 未处理 $n_warn 个"
}

# 定位完整产物目录 (u-boot/Image/rootfs x2 齐全才算完整): 顶层软链跑在 ~/qemu_dev/build/,
# 直跑 qemu-device/build_qemu.sh 在 qemu-device/build/; 找到则 echo 目录并返回 0
find_artifact_dir() {
    local dir
    for dir in "$DEV_DIR/build" "$DEV_DIR/qemu-device/build"; do
        if [ -s "$dir/uboot/u-boot.bin" ] && [ -s "$dir/kernel/arch/arm64/boot/Image" ] \
            && [ -s "$dir/rootfs.cpio.gz" ] && [ -s "$dir/rootfs-shell.cpio.gz" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

build_artifacts() {
    local force="$1" src=""
    if src="$(find_artifact_dir)" && [ "$force" -eq 0 ]; then
        step "检测到已有编译产物: $src, 跳过编译直接拷贝 (强制重编: ./start.sh -f)"
        return 0
    fi
    step "编译 QEMU 启动成果物 (busybox/u-boot/kernel/rootfs, 首次编译含 dropbear 下载) ..."
    # 调用 repo sync 由 manifest <linkfile> 生成的顶层软链: 脚本内部以链接所在目录
    # (~/qemu_dev) 为 ROOT, 与 busybox/kernel/u-boot 源码树同级, 产物落在 ~/qemu_dev/build/
    [ -e "$DEV_DIR/build_qemu.sh" ] || { echo "❌ 缺少 $DEV_DIR/build_qemu.sh (repo sync 应生成顶层软链)" >&2; exit 1; }
    "$DEV_DIR/build_qemu.sh" -b
    step "成果物就绪: $DEV_DIR/build/"
    echo "  u-boot:  $DEV_DIR/build/uboot/u-boot.bin"
    echo "  kernel:  $DEV_DIR/build/kernel/arch/arm64/boot/Image"
    echo "  rootfs:  $DEV_DIR/build/rootfs.cpio.gz (验证版)"
    echo "           $DEV_DIR/build/rootfs-shell.cpio.gz (交互版)"
}

# 编译产物拷到本脚本所在仓库的 .qemu/ (与 Dockerfile 同级): Dockerfile 的 COPY 只能
# 引用构建上下文内的文件, 而产物在 ~/qemu_dev (仓库外), 必须先搬进仓库;
# 打包 (build.sh) 只管 docker build, 不掺和产物的事
stage_artifacts() {
    local dst="$REPO_DIR/.qemu" src
    src="$(find_artifact_dir)" || { echo "❌ 未找到完整编译产物 (u-boot/Image/rootfs x2), 请先编译成功" >&2; exit 1; }
    mkdir -p "$dst"
    rm -f "$dst/u-boot.bin" "$dst/Image" "$dst/rootfs.cpio.gz" "$dst/rootfs-shell.cpio.gz"
    cp -f "$src/uboot/u-boot.bin" \
          "$src/kernel/arch/arm64/boot/Image" \
          "$src/rootfs.cpio.gz" \
          "$src/rootfs-shell.cpio.gz" \
          "$dst/" || { echo "❌ 成果物拷贝失败: $src -> $dst" >&2; exit 1; }
    step "成果物已拷贝到 $dst (来自 $src)"
    echo "打包进镜像: ./build.sh -b (COPY 到镜像 /root/.qemu, 容器内 qemu_boot 一键启动)"
}

main() {
    local do_build=0 force_build=0
    local opt
    while getopts "bfh" opt; do
        case $opt in
            b) do_build=1 ;;
            f) do_build=1 force_build=1 ;;
            h) usage; exit 0 ;;
            \?) usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    [ $# -eq 0 ] || { usage >&2; exit 1; }
    setup_git
    mkdir -p "$DEV_DIR"
    cd "$DEV_DIR"
    init_repo
    sync_code
    ensure_branches
    if [ "$do_build" -eq 1 ]; then
        build_artifacts "$force_build"
        stage_artifacts
    fi
    command -v code >/dev/null && code "$DEV_DIR" || true
}

main "$@"
