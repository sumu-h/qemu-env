#!/bin/bash
# =============================================================================
# verify.sh — 验证 qemu-env 镜像工具链完整性
#
# 用法:
#   bash verify.sh                              # 容器内直接运行
#   docker run --rm -v "$PWD/verify.sh":/verify.sh <image> bash /verify.sh
# =============================================================================

set -euo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== 验证 qemu-env 工具链 ==="
echo ""

# ----- 基础编译工具 -----
echo "[基础工具]"
check "gcc"          gcc --version
check "g++"          g++ --version
check "make"         make --version
check "python3"      python3 --version
check "ncurses.h"    test -f /usr/include/ncurses.h
check "locale zh_CN" bash -c 'locale -a 2>/dev/null | grep -q zh_CN'

echo ""
# ----- QEMU 模拟器 -----
echo "[QEMU 模拟器]"
check "qemu-x86_64"          qemu-x86_64 --version
check "qemu-aarch64"         qemu-aarch64 --version
check "qemu-riscv64"         qemu-riscv64 --version
check "qemu-system-x86_64"   qemu-system-x86_64 --version
check "qemu-system-aarch64"  qemu-system-aarch64 --version
check "qemu-system-riscv64"  qemu-system-riscv64 --version
check "qemu-img"             qemu-img --version
check "gdb-multiarch"        gdb-multiarch --version

echo ""
# ----- musl 交叉编译工具链 -----
echo "[musl 交叉编译器]"
check "aarch64-linux-musl-gcc" aarch64-linux-musl-gcc --version
check "riscv64-linux-musl-gcc" riscv64-linux-musl-gcc --version

echo ""
echo "=== 结果: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
