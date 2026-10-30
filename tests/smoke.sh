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

# --- 6. sysup 兼容性：reflector 的 "# When:" 时效标记 ---
printf '\n[6] sysup 兼容的时效标记\n'
# 直接照抄 sysup 的解析逻辑
when_str="$(sed -n 's/^# When:[[:space:]]*//p;T;q' "$SANDBOX/out5" 2>/dev/null || true)"
if [[ -n "$when_str" ]] && file_ts="$(date -u -d "${when_str% UTC}" +%s 2>/dev/null)"; then
    days_old=$((( $(date +%s) - file_ts ) / 86400))
    check "sysup 能解析时效标记（当前 ${days_old} 天）" "$([[ $days_old -eq 0 ]] && echo 0 || echo 1)"
else
    check "sysup 能解析时效标记（实际解析到: '${when_str}'）" 1
fi

# --- 7. 列表校验 ---
printf '\n[7] 写入前校验\n'
: > "$SANDBOX/empty"; validate_list "$SANDBOX/empty"; check "拒绝空文件" "$([[ $? != 0 ]] && echo 0 || echo 1)"
printf 'this is not a mirrorlist\n' > "$SANDBOX/junk"; validate_list "$SANDBOX/junk"
check "拒绝无 Server 行的内容" "$([[ $? != 0 ]] && echo 0 || echo 1)"
validate_list "$SANDBOX/src5"; check "接受正常列表" $?

# --- 8. 地区识别与邻近区域 ---
printf '\n[8] 地区识别 / 邻近区域\n'
check "normalize_cc: 小写代码 -> 大写" \
      "$([[ "$(normalize_cc cn)" == CN ]] && echo 0 || echo 1)"
check "normalize_cc: 国家全名 -> 代码" \
      "$([[ "$(normalize_cc China 2>/dev/null)" == CN ]] && echo 0 || echo 1)"
check "neighbor_codes: CN -> 含邻近地区" \
      "$(case "$(neighbor_codes CN)" in *JP*) echo 0 ;; *) echo 1 ;; esac)"

# --- 9. 同步一致性校验 ---
printf '\n[9] 同步一致性校验\n'
mkdir -p "$SANDBOX/cache9"
cat > "$SANDBOX/in9" <<'EOF'
Server = https://good.example/archlinux/$repo/os/$arch
Server = https://bad.example/archlinux/$repo/os/$arch
Server = https://noheader.example/archlinux/$repo/os/$arch
EOF
# 假 curl：按 URL 吐伪造响应头（基准 10:00Z；good 落后 5 分钟；bad 落后两天）
probe_fake_curl() {
    curl() {
        local url="" a
        for a in "$@"; do [[ "$a" == http* ]] && { url="$a"; break; }; done
        case "$url" in
            *geo.mirror.pkgbuild.com*) echo 'Last-Modified: Mon, 19 Oct 2026 10:00:00 GMT' ;;
            *good.example*)            echo 'Last-Modified: Mon, 19 Oct 2026 09:55:00 GMT' ;;
            *bad.example*)             echo 'Last-Modified: Sat, 17 Oct 2026 10:00:00 GMT' ;;
            *) return 1 ;;
        esac
    }
}
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache9"; OPT_TOLERANCE=3600; OPT_CHECK=true
    probe_fake_curl
    check_mirror_consistency "$SANDBOX/in9" "$SANDBOX/out9"
) >/dev/null 2>&1
if grep -q 'good.example' "$SANDBOX/out9" \
   && grep -q 'bad.example' "$SANDBOX/out9" \
   && grep -q 'noheader.example' "$SANDBOX/out9"; then
    check "一致性差的只降序、不剔除（三个都保留）" 0
else
    check "一致性差的只降序、不剔除（三个都保留）" 1
fi
# 顺序必须是：好 -> 未知 -> 差（输入里 bad 在中间，正确排序应把它挤到最后）
order="$(sed -E 's#^Server = https://([^/]+)/.*#\1#' "$SANDBOX/out9" | tr '\n' ' ')"
if [[ "$order" == 'good.example noheader.example bad.example ' ]]; then
    check "排序为 优先 -> 未知 -> 降序（实际: $order）" 0
else
    check "排序为 优先 -> 未知 -> 降序（实际: $order）" 1
fi
if grep -q '^Server = https://good.example' "$SANDBOX/out9"; then
    check "输出仍带 'Server = ' 前缀（回归：曾丢前缀使列表被清空）" 0
else
    check "输出仍带 'Server = ' 前缀（回归：曾丢前缀使列表被清空）" 1
fi
# 全部滞后时也要保留原顺序（自然退化为不排序）
printf 'Server = https://bad.example/archlinux/$repo/os/$arch\nServer = https://good.example/archlinux/$repo/os/$arch\n' > "$SANDBOX/in9b"
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache9"; OPT_TOLERANCE=3600
    probe_fake_curl
    check_mirror_consistency "$SANDBOX/in9b" "$SANDBOX/out9b"
) >/dev/null 2>&1
order="$(sed -E 's#^Server = https://([^/]+)/.*#\1#' "$SANDBOX/out9b" | tr '\n' ' ')"
if [[ "$order" == 'good.example bad.example ' ]] && (( $(wc -l < "$SANDBOX/out9b") == 2 )); then
    check "混合滞后时好的优先、差的排后（实际: $order）" 0
else
    check "混合滞后时好的优先、差的排后（实际: $order）" 1
fi
# 放宽容忍度后 bad 应回到「优先」档，保持输入原顺序
(
    sudo() { fake_sudo "$@"; }
    CACHE_DIR="$SANDBOX/cache9"; OPT_TOLERANCE=999999
    probe_fake_curl
    check_mirror_consistency "$SANDBOX/in9b" "$SANDBOX/out9c"
) >/dev/null 2>&1
order="$(sed -E 's#^Server = https://([^/]+)/.*#\1#' "$SANDBOX/out9c" | tr '\n' ' ')"
if [[ "$order" == 'bad.example good.example ' ]]; then
    check "--tolerance 放宽后不再降序，保持原顺序（实际: $order）" 0
else
    check "--tolerance 放宽后不再降序，保持原顺序（实际: $order）" 1
fi

# --- 10. 备份清理（按文件名，不按 mtime）---
printf '\n[10] 备份清理\n'
mkdir -p "$SANDBOX/cache10"
for i in 01 02 03 04 05; do
    printf 'x\n' > "$SANDBOX/cache10/mirrorlist.202600${i}-120000.bak"
done
# 故意把最旧的那份改成最新 mtime：旧实现按 mtime 排会删错
# （备份用 cp -p 保留了原文件 mtime，所以排序依据本来就不该是 mtime）
touch "$SANDBOX/cache10/mirrorlist.20260001-120000.bak"
ln -sfn mirrorlist.20260005-120000.bak "$SANDBOX/cache10/mirrorlist.latest.bak"
(
    CACHE_DIR="$SANDBOX/cache10"; KEEP_BACKUPS=3
    prune_backups mirrorlist
)
remain="$(ls -1 "$SANDBOX/cache10"/*.bak 2>/dev/null | grep -v latest | wc -l)"
if [[ "$remain" == 3 ]] \
   && [[ -f "$SANDBOX/cache10/mirrorlist.20260005-120000.bak" ]] \
   && [[ ! -e "$SANDBOX/cache10/mirrorlist.20260001-120000.bak" ]] \
   && [[ -L "$SANDBOX/cache10/mirrorlist.latest.bak" ]]; then
    check "保留最近 3 份、不误删软链、不被 mtime 干扰" 0
else
    check "保留最近 3 份、不误删软链、不被 mtime 干扰 (剩 $remain)" 1
fi

# --- 11. 辅助函数 ---
printf '\n[11] 辅助函数\n'
printf 'Server = https://a.example/x\n# Server = https://b.example/x\nServer = garbage\n' \
    > "$SANDBOX/count11"
check "server_count 只数合法 Server 行" \
      "$([[ "$(server_count "$SANDBOX/count11")" == 1 ]] && echo 0 || echo 1)"
check "fmt_dur: 3725 -> 1h2m" "$([[ "$(fmt_dur 3725)" == 1h2m ]] && echo 0 || echo 1)"
check "fmt_dur: 负数归零" "$([[ "$(fmt_dur -5)" == 0s ]] && echo 0 || echo 1)"

# --- 12. 默认值（防止被改回会导致候选过少的设置）---
printf '\n[12] 默认值\n'
check "默认 --max-delay = 86400（24h）" "$([[ "$OPT_MAX_DELAY" == 86400 ]] && echo 0 || echo 1)"
check "默认 --completion = 0.95" "$([[ "$OPT_COMPLETION" == 0.95 ]] && echo 0 || echo 1)"
check "默认开启一致性校验" "$([[ "$OPT_CHECK" == true ]] && echo 0 || echo 1)"
check "默认 --tolerance = 3600" "$([[ "$OPT_TOLERANCE" == 3600 ]] && echo 0 || echo 1)"
check "默认不自动刷库（--sync 可选）" "$([[ "$OPT_SYNC" == false ]] && echo 0 || echo 1)"

# --- 13. 备份失败必须中止（回归：曾继续裸写，中断后无法回滚）---
printf '\n[13] 备份失败中止\n'
(
    CACHE_DIR="$SANDBOX/cache13"; mkdir -p "$CACHE_DIR"
    target13="$SANDBOX/target13.conf"; printf 'ORIGINAL\n' > "$target13"
    # 只让备份用的 `cp -p` 失败，其余 sudo 调用照常
    sudo() {
        case "$1" in
            chown|-v) return 0 ;;
            cp) [[ "${2:-}" == -p ]] && return 1 ;;
        esac
        "$@"
    }
    register_target "$target13"
) 2>/dev/null
rc=$?
if [[ $rc == 1 && "$(cat "$SANDBOX/target13.conf")" == ORIGINAL ]]; then
    check "备份失败时中止，原文件未被覆盖" 0
else
    check "备份失败时中止，原文件未被覆盖 (rc=$rc)" 1
fi

# --- 14. 中断清理（回归：Ctrl-C 会残留 probe.XXXXXX）---
printf '\n[14] 中断清理\n'
(
    CACHE_DIR="$SANDBOX/cache14"; mkdir -p "$CACHE_DIR"
    d="$(mktemp -d "$CACHE_DIR/probe.XXXXXX")"
    PROBE_DIRS+=("$d")
    printf '%s\n' "$d" > "$SANDBOX/probe_path"
    trap cleanup EXIT INT TERM HUP
    # $$ 在子 shell 里仍是父进程 PID，必须用 BASHPID
    kill -INT "$BASHPID"
)
probe_path="$(cat "$SANDBOX/probe_path" 2>/dev/null || true)"
if [[ -n "$probe_path" && ! -d "$probe_path" ]]; then
    check "Ctrl-C 后探测目录被清理" 0
else
    check "Ctrl-C 后探测目录被清理 (残留: ${probe_path:-未记录})" 1
fi

# --- 15. 头部元数据 ---
printf '\n[15] 头部元数据\n'
printf 'Server = https://a.example/x\n' > "$SANDBOX/src15"
compose_list "$SANDBOX/src15" "$SANDBOX/out15" rate-mirrors CN CN "$FALLBACK_MIRROR"
if grep -qx '## Region: CN' "$SANDBOX/out15"; then
    check "单国模式不重复 candidates" 0
else
    check "单国模式不重复 candidates" 1
fi
compose_list "$SANDBOX/src15" "$SANDBOX/out15n" rate-mirrors CN "CN,HK" "$FALLBACK_MIRROR"
if grep -qx '## Region: CN (candidates: CN,HK)' "$SANDBOX/out15n"; then
    check "--neighbors 模式列出候选地区" 0
else
    check "--neighbors 模式列出候选地区" 1
fi
compose_list "$SANDBOX/src15" "$SANDBOX/out15c" rate-mirrors archlinuxcn "" "$FALLBACK_CN_MIRROR" "n/a"
if grep -qx '## Region: archlinuxcn' "$SANDBOX/out15c" \
   && grep -q 'max-delay=n/a' "$SANDBOX/out15c"; then
    check "archlinuxcn 不声称地区过滤，延迟标 n/a" 0
else
    check "archlinuxcn 不声称地区过滤，延迟标 n/a" 1
fi

# --- 16. --completion 参数 ---
printf '\n[16] 完成度参数\n'
(
    OPT_COMPLETION=1
    parse_args --completion 0.9
    [[ "$OPT_COMPLETION" == 0.9 ]]
)
check "--completion 0.9 被接受" $?
(
    OPT_COMPLETION=0.95
    parse_args --completion 1.5
) >/dev/null 2>&1
check "--completion 1.5 被拒绝" "$([[ $? != 0 ]] && echo 0 || echo 1)"
(
    OPT_COMPLETION=0.95
    parse_args --completion 1
    [[ "$OPT_COMPLETION" == 1 ]]
)
check "--completion 1 被接受" $?
# 命令构造：completion 与 max-delay 必须真正传给 rate-mirrors
(
    CACHE_DIR="$SANDBOX/cache16"; mkdir -p "$CACHE_DIR"
    OPT_COMPLETION=0.95; OPT_MAX_DELAY=86400; OPT_PROTOCOL=https
    OPT_CONCURRENCY=16; OPT_PER_COUNTRY=5; OPT_MIRRORS=10; OPT_QUIET=false
    rate-mirrors() {
        printf '%s\n' "$*" > "$SANDBOX/args16"
        local a save=""
        for a in "$@"; do [[ "$a" == --save=* ]] && save="${a#--save=}"; done
        printf 'Server = https://fake.example/archlinux/$repo/os/$arch\n' > "$save"
    }
    generate_list "$SANDBOX/out16" rate-mirrors CN CN
) >/dev/null 2>&1
if grep -q -- '--completion=0.95' "$SANDBOX/args16" \
   && grep -q -- '--max-delay=86400' "$SANDBOX/args16"; then
    check "generate_list 把 completion/max-delay 传给后端" 0
else
    check "generate_list 把 completion/max-delay 传给后端" 1
fi

printf '\n=== 结果: %d 通过, %d 失败 ===\n\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
