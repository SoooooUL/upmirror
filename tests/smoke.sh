#!/usr/bin/env bash
# ==============================================================================
#  upmirror 冒烟测试
#
#  不触碰 /etc：全部在沙箱目录里跑，并用假的 sudo 代替提权。
#  重点覆盖「只有真正写盘时才会执行到」的代码路径 —— 这类 bug 在 --dry-run
#  下永远不会暴露。
#
#  用法: bash tests/smoke.sh
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$SCRIPT_DIR/upmirror"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/upmirror-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0 FAIL=0
check() {   # $1=描述 $2=0/非0
    if [[ "$2" == 0 ]]; then
        printf '  \033[1;32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  \033[1;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1))
    fi
}

printf '\n=== upmirror smoke tests ===\n\n'

# --- 0. 语法 ---
bash -n "$TARGET"; check "bash -n 语法检查" $?

# 只加载函数（有 BASH_SOURCE 守卫，不会执行 main）
# shellcheck disable=SC1090
source "$TARGET" >/dev/null 2>&1
check "source 时不会自动执行 main" $?

# 假 sudo：chown 直接放行，其余原样执行
fake_sudo() {
    case "${1:-}" in
        chown) return 0 ;;
        -v)    return 0 ;;
    esac
    "$@"
}

# --- 1. install_atomic：原子替换 ---
printf '\n[1] install_atomic 原子替换\n'
if (
    sudo() { fake_sudo "$@"; }
    cp_src="$SANDBOX/new.conf"; printf 'Server = https://example.org/archlinux/\n' > "$cp_src"
    dst="$SANDBOX/target1.conf"; printf 'OLD\n' > "$dst"
    install_atomic "$cp_src" "$dst"
); then
    if grep -q 'example.org' "$SANDBOX/target1.conf" && [[ ! -e "$SANDBOX/target1.conf.upmirror.new" ]]; then
        check "内容已替换且无残留临时文件" 0
    else
        check "内容已替换且无残留临时文件" 1
    fi
    check "权限为 0644" "$([[ "$(stat -c %a "$SANDBOX/target1.conf")" == 644 ]] && echo 0 || echo 1)"
else
    check "install_atomic 执行成功（曾因 local 同行引用未绑定变量而崩溃）" 1
fi

# --- 2. 失败回滚：恢复原文件 ---
printf '\n[2] 失败时自动回滚（原有文件）\n'
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache1"; mkdir -p "$CACHE_DIR"
    RB_TARGETS=(); RB_BACKUPS=(); RB_STATE=(); TMP_FILES=(); SCRIPT_OK=false
    printf 'ORIGINAL\n' > "$SANDBOX/target2.conf"
    trap cleanup EXIT
    register_target "$SANDBOX/target2.conf" >/dev/null
    printf 'BROKEN\n' > "$SANDBOX/target2.conf"     # 模拟写坏
    exit 3                                          # 未设置 SCRIPT_OK -> 应回滚
) >/dev/null 2>&1
rc=$?
if [[ $rc == 3 ]] && grep -q '^ORIGINAL$' "$SANDBOX/target2.conf"; then
    check "原文件被还原且保留原退出码" 0
else
    check "原文件被还原且保留原退出码 (rc=$rc)" 1
fi

# --- 3. 失败回滚：目标原本不存在 -> 删除新建文件 ---
printf '\n[3] 失败时自动回滚（原本不存在）\n'
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache2"; mkdir -p "$CACHE_DIR"
    RB_TARGETS=(); RB_BACKUPS=(); RB_STATE=(); TMP_FILES=(); SCRIPT_OK=false
    trap cleanup EXIT
    register_target "$SANDBOX/target3.conf" >/dev/null
    printf 'NEW\n' > "$SANDBOX/target3.conf"
    exit 1
) >/dev/null 2>&1
if [[ ! -e "$SANDBOX/target3.conf" ]]; then
    check "新建文件被删除" 0
else
    check "新建文件被删除" 1
fi

# --- 4. 成功时不回滚，且临时文件被清理 ---
printf '\n[4] 成功路径不回滚 + 清理临时文件\n'
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache3"; mkdir -p "$CACHE_DIR"
    RB_TARGETS=(); RB_BACKUPS=(); RB_STATE=(); TMP_FILES=(); SCRIPT_OK=false
    trap cleanup EXIT
    printf 'ORIGINAL\n' > "$SANDBOX/target4.conf"
    register_target "$SANDBOX/target4.conf" >/dev/null
    printf 'UPDATED\n' > "$SANDBOX/target4.conf"
    # 回归防护：new_tmp 必须能把文件登记到调用者的 TMP_FILES 里
    # （曾经用命令替换调用，数组修改丢在子 shell 里，临时文件从未被清理）
    tmp=""; new_tmp tmp t
    printf 'x' > "$tmp"
    [[ -n "${TMP_FILES[*]:-}" ]] || { echo 'TMP_FILES 未登记' >&2; exit 9; }
    SCRIPT_OK=true
    exit 0
) >/dev/null 2>&1
rc=$?
if [[ $rc == 0 ]] && grep -q '^UPDATED$' "$SANDBOX/target4.conf" \
   && [[ -z "$(ls -A "$SANDBOX/cache3"/t.* 2>/dev/null)" ]]; then
    check "新内容保留且临时文件已清理" 0
else
    check "新内容保留且临时文件已清理 (rc=$rc)" 1
fi

# --- 5. 保底镜像 ---
printf '\n[5] 保底镜像拼接\n'
printf 'Server = https://a.example/archlinux/\n' > "$SANDBOX/src5"
OPT_FALLBACK=true
compose_list "$SANDBOX/src5" "$SANDBOX/out5" rate-mirrors CN CN "$FALLBACK_MIRROR"
if grep -q '^Server = https://mirrors.cernet.edu.cn/archlinux/\$repo/os/\$arch$' "$SANDBOX/out5"; then
    check "默认追加教育网联合镜像站" 0
else
    check "默认追加教育网联合镜像站" 1
fi
OPT_FALLBACK=false
compose_list "$SANDBOX/src5" "$SANDBOX/out5b" rate-mirrors CN CN "$FALLBACK_MIRROR"
if ! grep -q cernet "$SANDBOX/out5b"; then
    check "--no-fallback 时不再追加" 0
else
    check "--no-fallback 时不再追加" 1
fi
OPT_FALLBACK=true
if [[ "$(grep -c '^Server = ' "$SANDBOX/out5")" == 2 ]]; then
    check "保底镜像位于列表末尾" 0
else
    check "保底镜像位于列表末尾" 1
fi

# --- 6. 列表校验 ---
printf '\n[6] 写入前校验\n'
: > "$SANDBOX/empty"; validate_list "$SANDBOX/empty"; check "拒绝空文件" "$([[ $? != 0 ]] && echo 0 || echo 1)"
printf 'this is not a mirrorlist\n' > "$SANDBOX/junk"; validate_list "$SANDBOX/junk"
check "拒绝无 Server 行的内容" "$([[ $? != 0 ]] && echo 0 || echo 1)"
validate_list "$SANDBOX/src5"; check "接受正常列表" $?

# --- 7. 地区识别与邻近区域 ---
printf '\n[7] 地区识别 / 邻近区域\n'
check "normalize_cc: 小写代码 -> 大写" \
      "$([[ "$(normalize_cc cn)" == CN ]] && echo 0 || echo 1)"
check "normalize_cc: 国家全名 -> 代码" \
      "$([[ "$(normalize_cc China 2>/dev/null)" == CN ]] && echo 0 || echo 1)"
check "neighbor_codes: CN -> 含邻近地区" \
      "$(case "$(neighbor_codes CN)" in *JP*) echo 0 ;; *) echo 1 ;; esac)"

printf '\n=== 结果: %d 通过, %d 失败 ===\n\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
