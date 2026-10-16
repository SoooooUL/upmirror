# upmirror

Arch Linux 镜像源更新器 —— 默认基于 [rate-mirrors](https://github.com/westandskif/rate-mirrors)，
自动测速并生成 `/etc/pacman.d/mirrorlist`，末尾附带 **教育网联合镜像站** 保底。

## 为什么不用 reflector

- reflector 是 Python 写的，请求带 `Python-urllib/x.y` 的 User-Agent。
  实测 `mirrors.hust.edu.cn` 等站点会直接掐断这类 UA 的连接
  （`RemoteDisconnected: Remote end closed connection without response`），
  导致测速永远 0 KiB/s。
- reflector 会在半死镜像上耗尽超时，整体经常要跑几分钟；
  rate-mirrors 约 10~30 秒完成，且会提前过滤未同步完成的镜像。

## 特性

1. **自动识别地区**：时区映射 → IP 定位兜底 → 手动 `-c` 指定
2. **失败自动回滚**：写入前备份，脚本中断/出错时 `trap` 自动还原原文件
3. **绝不写坏文件**：写入前校验（非空、至少一行 `Server =`），且原子替换
4. **保底镜像**：末尾追加教育网联合镜像站，前面全部不可用时仍能救急
5. **可选 archlinuxcn**：`--cn` 一并更新 `/etc/pacman.d/archlinuxcn-mirrorlist`

## 依赖

```bash
sudo pacman -S rate-mirrors   # 推荐后端，官方 extra 仓库
sudo pacman -S reflector      # 可选备用后端 / 也用于国家名反查
```

## 安装

```bash
git clone https://github.com/SoooooUL/upmirror.git ~/Projects/upmirror
ln -sf ~/Projects/upmirror/upmirror ~/.local/bin/upmirror
```

## 使用

```bash
upmirror                          # 自动检测地区并更新
upmirror -c JP                    # 强制使用日本镜像
upmirror --neighbors              # 放宽到邻近国家/地区（如 CN,HK,TW,JP,KR,SG）
upmirror --cn                     # 顺带更新 archlinuxcn 镜像列表
upmirror --dry-run                # 只测速并打印，不写入任何文件
upmirror -y                       # 跳过交互确认（适合定时任务）
```

### 选项

| 选项 | 说明 | 默认 |
|---|---|---|
| `-c, --country <CC>` | 国家/地区 ISO 代码（也接受国家全名） | 自动检测 |
| `-n, --mirrors <N>` | 写入列表的服务器数量 | 10 |
| `--max-delay <SEC>` | 镜像最大同步延迟 | 43200（12h） |
| `--protocol <P>` | `https` / `http` / `both` | https |
| `--concurrency <N>` | 并发测速数 | 16 |
| `--per-country <N>` | 每国测速镜像数 | 5 |
| `--neighbors` | 放宽到邻近国家/地区 | 关 |
| `--cn` | 同时更新 archlinuxcn 镜像列表 | 关 |
| `--backend <B>` | `auto` / `rate-mirrors` / `reflector` | auto |
| `--dry-run` | 只预览不写入 | 关 |
| `--no-fallback` | 不追加保底镜像 | 关 |
| `-y, --yes` | 跳过交互确认 | 关 |

## 保底镜像（教育网联合镜像站）

列表末尾始终会追加：

```
Server = https://mirrors.cernet.edu.cn/archlinux/$repo/os/$arch
```

- 教育网联合镜像站（[MirrorZ](https://mirrors.cernet.edu.cn/)）2026-08-22 正式发布，
  由 TUNA 于 2020 年发起，CERNET 网络中心提供域名与网络资源，现有 27+ 家高校成员。
- 它**不存储镜像内容**，而是作为统一入口做 302 智能跳转：
  按「镜像站最近同步时间 + 用户 IP 城市距离 + IPv4/IPv6 + 校内站点 IP 段」动态选择成员站，
  成员站维护时会自动改跳它站。
- 它**不在 Arch 官方镜像列表**（mirror status JSON）中，
  因此 rate-mirrors / reflector 都不会自动选到，必须手动追加。
- pacman 按顺序取优先级，所以放在**最末尾**表示：只有前面所有镜像都不可用时才使用它。

## 备份与回滚

备份保存在 `~/.cache/upmirror/`：

```
mirrorlist.20261016-183500.bak      # 带时间戳
mirrorlist.latest.bak -> ...        # 最近一次
```

- 每个目标文件保留最近 10 份备份，旧的自动清理。
- 脚本被 `Ctrl-C`、被 kill 或中途出错时，会自动从备份恢复原文件；
  如果目标文件原本不存在，则删除新建的文件。
- `--dry-run` 不涉及任何写入，自然也不会触发回滚。

## 定时任务示例

```bash
# 每周一 9:17 静默更新（无交互）
17 9 * * 1 /home/ice_sheep/.local/bin/upmirror -y >/dev/null 2>&1
```

## License

MIT
