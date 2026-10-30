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
2. **同步一致性校验（默认开）**：写入前把每个候选镜像的 `core.db` / `extra.db`
   的 `Last-Modified` 与官方 geomirror 比对，把滞后超过阈值的镜像
   **排到列表末尾**（不剔除）—— 只按速度排序会选到「core 旧、extra 新」的
   镜像，进而导致部分升级（见下文）
3. **失败自动回滚**：写入前备份，脚本中断/出错时 `trap` 自动还原原文件
4. **绝不写坏文件**：写入前校验（非空、带协议的 `Server =`），且原子替换
5. **保底镜像**：末尾追加教育网联合镜像站，前面全部不可用时仍能救急
6. **可选 archlinuxcn**：`--cn` 一并更新 `/etc/pacman.d/archlinuxcn-mirrorlist`
7. **可选强制刷库**：`--sync` 写入后执行 `pacman -Syy`

## 为什么需要「同步一致性校验」

Arch Wiki 的 [Mirrors](https://wiki.archlinux.org/title/Mirrors) 页写得很直接：
*"It is not optimal to only rank mirrors based on speed since the fastest servers
might be out-of-sync."* 但比「整个镜像旧」更阴的是**只同步了一半**的镜像。

实测案例（2026-10-19，本机）：

| 镜像 | core.db `Last-Modified` | extra.db `Last-Modified` | 后果 |
|---|---|---|---|
| mirrors.aliyun.com | 10-18 15:47 UTC | 10-19 07:21 UTC | core 落后 **15h33m** |
| mirror.nyist.edu.cn | 10-18 18:00 UTC | 10-19 00:56 UTC | core 落后 **15h33m** |
| mirrors.xjtu.edu.cn | 10-19 07:21 UTC | 10-19 07:54 UTC | extra 落后 **2h23m** |
| mirrors.jlu.edu.cn | 10-19 07:21 UTC | 10-19 10:08 UTC | 正常（9m） |

`perl` 在 **core**，而所有 `perl-*` 模块在 **extra**。于是 pacman 拿着
「旧 core + 新 extra」两套时间点的数据库做了一次事务：

- `perl` 本体仍是 `5.42.3-1`（不升级）
- `perl-proc-processtable` 等已按 `5.44` 重编译并安装
- 结果：`needrestart` 钩子报 `Can't locate Proc/ProcessTable.pm in @INC`

`rate-mirrors --max-delay` 和 `reflector --delay` 用的都是镜像站上报的
`last_sync` / `delay`，只能说明「最近同步过」，**盖不住单个仓库的滞后**：
阿里云当时 `delay` 约 8.6 小时，小于原先 12 小时的阈值，顺利通过筛选。

也正因为 `delay` 只是粗筛，`--max-delay` 不该收得太紧：2026-10-27 实测
官方 mirror status 里 CN 的 https 镜像只有 18 个，其中同步完成
（`completion_pct = 1`）的只有 4~7 个（随同步窗口波动），再要求
`delay <= 2h` 就只剩 3 个 —— 这就是「列表长期只有几个镜像」的根因。
现在默认值与 rate-mirrors 自身一致（24h），过期的镜像交给一致性校验
按真实 `core.db` / `extra.db` 时间戳降序。

完成度同理，`--completion` 默认取 **0.95** 而不是 rate-mirrors 的 1.0。
CN 的镜像长期停在 0.96~0.99（同步进行中），取 1.0 时 18 个 https 镜像里
只剩 3~4 个 —— 2026-10-27 实测：只有 `ustc`/`nju`/`aliyun` 是 1.0，
`jlu` 0.989、`hit` 0.978、`xjtu` 0.978、`sjtug` 0.978 全被滤掉，
这就是「CN 源明明有好几个，列表里却只有两三个」的原因。取 0.95 后
同一时刻能拿到 9 个。

`completion < 1` 的实际后果是少数包文件尚未到站，pacman 下载时 404
会自动换下一个 Server；db 之间的不一致仍由一致性校验负责。想严格遵循
Arch Wiki「completion < 1 的镜像不该用」的建议，传 `--completion 1`。

所以 upmirror 现在直接探测各镜像 `core.db` / `extra.db` 的 `Last-Modified`，
以官方 `geo.mirror.pkgbuild.com` 为基准逐个比对。

**不会被网络拖住**：

- 每个请求 `--max-time 5`，所有镜像（含基准站）**并行**探测
- 超时直接当「未知」，**不会**再发第二次请求（只有站点明确回 405/501
  不支持 HEAD 时，才退回「只取 1 字节的 GET」）
- 单个探测子进程有 watchdog，最长 `5×2+3 = 13` 秒后强杀
- 基准站拿不到 → 打印警告、**跳过一次致性校验**，列表原样写入
- 拿不到时间戳的镜像标为「未知」并**保留**，不会因为网络差把列表清空
- 超过一半镜像探测失败时会提示「可能是本地网络问题」

实测：裸连（无代理）下整个校验约 2 秒；两个黑洞地址 10 秒；基准站
不可达 11 秒后跳过。真不想等就用 `--no-check` 关掉。

用 `--tolerance` 调容忍秒数（默认 3600），或用 `--no-check` 关闭。

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
upmirror --sync                   # 写入后顺手 pacman -Syy 强制刷库
upmirror -y                       # 跳过交互确认（适合定时任务）
```

### 选项

| 选项 | 说明 | 默认 |
|---|---|---|
| `-c, --country <CC>` | 国家/地区 ISO 代码（也接受国家全名） | 自动检测 |
| `-n, --mirrors <N>` | 写入列表的服务器数量 | 10 |
| `--max-delay <SEC>` | 镜像最大同步延迟 | 86400（24h） |
| `--completion <R>` | 镜像同步完成度下限（0~1，仅 rate-mirrors 后端） | 0.95 |
| `--protocol <P>` | `https` / `http` / `both` | https |
| `--concurrency <N>` | 并发测速数 | 16 |
| `--per-country <N>` | 每国测速镜像数 | 5 |
| `--neighbors` | 放宽到邻近国家/地区 | 关 |
| `--cn` | 同时更新 archlinuxcn 镜像列表 | 关 |
| `--backend <B>` | `auto` / `rate-mirrors` / `reflector` | auto |
| `--dry-run` | 只预览不写入 | 关 |
| `--check` | 写入前校验镜像同步是否落后官方 | **开** |
| `--no-check` | 关闭同步一致性校验 | — |
| `--tolerance <SEC>` | 一致性校验容忍的落后秒数 | 3600（1h） |
| `--sync` | 写入后执行 `sudo pacman -Syy` | 关 |
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

- 每个目标文件保留最近 10 份备份，旧的自动清理。清理按**文件名**里的时间戳排序，
  不按 mtime（备份用 `cp -p` 保留了原文件的 mtime，按 mtime 排会在你手改过
  mirrorlist 之后删错文件）；`latest.bak` 是软链，不占备份份数。
- 脚本被 `Ctrl-C`、被 kill 或中途出错时，会自动从备份恢复原文件；
  如果目标文件原本不存在，则删除新建的文件。
- **备份失败会直接中止**（如权限、磁盘满）：没有备份的覆盖一旦中断就再也
  恢复不了，所以此时宁可什么都不写。
- 一致性校验的探测临时目录也会在中断时清理，不在 `~/.cache/upmirror` 留垃圾。
- `--dry-run` 不涉及任何写入，自然也不会触发回滚。

## 测试

```bash
bash tests/smoke.sh
```

测试在沙箱目录里跑，并用假的 `sudo` 代替提权，不会触碰 `/etc`。
重点覆盖只有真正写盘时才会执行到的代码路径（原子替换、备份回滚、
临时文件清理），这类 bug 在 `--dry-run` 下永远不会暴露。

另外用假的 `curl` 注入伪造的 `Last-Modified`，覆盖一致性校验的
「优先 / 未知 / 降序」三档排序 / `--tolerance` 放宽」四条分支，
以及备份清理的排序行为（含「软链不计数」「不被 mtime 干扰」）。

回归项：备份失败必须中止（不允许裸写）、`Ctrl-C` 后探测目录不残留、
单国模式头部不重复 `candidates`。

## 实现依据（源码/实测核对）

| 结论 | 依据 |
|---|---|
| pacman 会跟随 302 跳转（最多 10 次） | `lib/libalpm/dload.c`：`CURLOPT_FOLLOWLOCATION, 1L` / `CURLOPT_MAXREDIRS, 10L` |
| mirrorlist 顺序即尝试优先级，靠前优先 | `lib/libalpm/alpm_list.c` 的 `alpm_list_add` 挂到链表尾；`dload.c` 的 `payload_next_server` 从头部依次取 |
| 同一主机累计 3 次软错误即在本次事务内被跳过，DNS 失败等硬错误立即拉黑 | `dload.c`：`const int server_error_limit = 3;` |
| 下载速度 < 1 B/s 持续 10 秒才放弃该镜像 | `dload.c`：`CURLOPT_LOW_SPEED_LIMIT 1L` / `CURLOPT_LOW_SPEED_TIME 10L` |
| 教育网联合镜像站不在 Arch 官方 mirror status 列表中 | `https://archlinux.org/mirrors/status/json/`，1190 条中 cernet 条目数为 0 |
| 部分镜像站会断开 `Python-urllib` UA 的请求（即 reflector 失败的真正原因） | 实测 `mirrors.hust.edu.cn`：curl 200；urllib → `RemoteDisconnected`；urllib + `curl/8.14.1` UA → 200 |
| 只按速度排序会选到过期镜像 | Arch Wiki `Mirrors`：「It is not optimal to only rank mirrors based on speed since the fastest servers might be out-of-sync」 |
| 只能用 `Last-Modified` 反查 db 来源 | 实测本机 `/var/lib/pacman/sync/core.db` 的 mtime 精确等于镜像上的 `Last-Modified`（2026-10-18 15:47 UTC = aliyun） |
| `reflector` 支持小数 `--delay` 与逗号多国 `--country` | `reflector --help` / `man reflector`：「n may be an integer or a decimal number」 |
| `rate-mirrors` 有 `--completion` 与 `--disable-untested-fallback` | `rate-mirrors arch --help`；前者默认 1（排除正在同步的镜像），后者防止全部测速失败时输出未测速镜像 |

### 实测记录（2026-10-16，CN）

用 `fakeroot -- pacman -Sy --dbpath <临时目录> --debug` 抓取 pacman 真实请求的 URL：

- `core.db` / `extra.db` / `multilib.db` 及其 `.sig` 全部命中列表第 1 位的
  `mirrors.jlu.edu.cn`，没有往下 fallback —— 排序生效。
- 把临时 dbpath 里的 db 清空、并故意不传 `--disable-sandbox-filesystem`（模拟下载失败）后，
  pacman 会把 8 个 Server 依次试完，**包括末尾的 `mirrors.cernet.edu.cn` 保底** ——
  兜底链路确实会被触达。
- 注意：用 fakeroot + 临时 dbpath 手工验证时需要加 `--disable-sandbox-filesystem`，
  否则会因 pacman 自身的下载沙箱（`sandboxuser: alpm`）报“无法获取某些文件”，
  与镜像无关；正常 `sudo pacman -Syu` 不受影响。

## 接入 sysup（shorin-contrib）

sysup 的镜像更新步骤有两个硬约定，upmirror 都已兼容：

| sysup 的行为 | upmirror 的配合 |
|---|---|
| `find_mirror_script()` 只认 `mirror-update` 这个名字 | 仓库提供 `contrib/mirror-update` 入口脚本 |
| 用 `sed -n 's/^# When:...//p'` 解析 mirrorlist 时效，解析不到就直接跳过 | 生成的文件带有 reflector 格式的 `# When: YYYY-MM-DD HH:MM:SS UTC` 行 |

安装（只改用户目录里的软链，不动包管理的文件）：

```bash
ln -sf ~/Projects/upmirror/contrib/mirror-update ~/.local/bin/mirror-update
```

入口脚本实际执行 `upmirror -y -q`：免交互确认，测速输出写进
`~/.cache/upmirror/last-run.log`，不糊满 sysup 的输出。
原脚本仍在 `/usr/lib/shorin-contrib/mirror-update`，可显式调用；想恢复原状：

```bash
ln -sf /usr/lib/shorin-contrib/mirror-update ~/.local/bin/mirror-update
```

注意事项：

- sysup 只在镜像源超过 `MIRROR_MAX_DAYS`（默认 30 天）时才更新镜像，
  该常量在 `/usr/lib/shorin-contrib/sysup` 里；想让每次 sysup 都刷新可改成 0，
  但该文件属于 shorin-contrib 包，改动会被包更新覆盖。
- sysup 的镜像步骤只更新 Arch 主仓库的 mirrorlist；archlinuxcn 需要另行
  `upmirror --cn`。

## 定时任务示例

```bash
# 每周一 9:17 静默更新（无交互）
17 9 * * 1 /home/ice_sheep/.local/bin/upmirror -y >/dev/null 2>&1
```

## License

MIT
