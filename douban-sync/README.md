# 觅影(OmniPlay) 豆瓣评分 + 海报自动同步器

> 给你 Mac 上的觅影（OmniPlay）自动补上**豆瓣评分**和**豆瓣海报**——每次启动觅影自动执行一次，无需手动逐条绑定。

## 它解决什么问题

觅影默认显示 **TMDB 评分**；豆瓣评分（绿色徽章）本来需要你**手动逐部绑定**豆瓣条目（悬停海报 → 放大镜 → 粘贴链接），费时费力。

本工具把"手动绑定"自动化：批量查豆瓣 → 自动匹配 → 把豆瓣评分/人数/简介/海报直写进觅影自己的 SQLite 数据库，并让海报墙优先展示豆瓣海报。

**原理说明**（为什么这样可行）：觅影的海报卡片每次刷新都会实时查本地 SQLite 的 `doubanMetadata` 表。所以只要往这张表里写入正确的豆瓣记录，绿徽章和豆瓣海报就会自动出现——和你亲手在 App 里绑定效果完全一致。数据只在你本机流转，不需要任何服务器，也不需要 Docker。

## 特性

- **自动匹配 + 防重名**：按片名精确匹配，同名多候选时用「年份」消歧（如《无人知晓》2004/2020 两版）；仍无法判定的**不会瞎写**，记入 `review.tsv` 等你人工处理
- **豆瓣海报优先**：只要豆瓣有海报就替换 `movie.posterPath`（觅影源码认可的 `doubanio.com/view/photo/.../public/` 规格，海报墙直接认）
- **评分到期自动刷新**：记录默认有效 30 天，到期后按已有 subjectId 重新抓取，评分随豆瓣变动而更新
- **请求节奏与觅影一致**：≥12s + 3~8s 随机抖动，避免给对方服务器造成压力（在 App 里手动绑定也是这个节奏）
- **零依赖**：只用 macOS 自带的 `/usr/bin/python3`，不装任何东西
- **写入前自动备份**：SQLite 在线备份到 `~/.omniplay-douban-sync/backups/`（保留最近 8 份）

## 安装

```bash
cd douban-sync
./install.sh
```

安装会：
1. 拷贝程序到 `~/.omniplay-douban-sync/`
2. 注册一个 LaunchAgent 守护进程（`com.omniplay.douban-sync`）
3. 守护进程每 3 秒检测觅影：**每次检测到觅影启动，等 12 秒后自动同步一次**
4. 安装完成后建议手动跑一次首轮同步（见下）

## 首轮同步 / 手动执行

```bash
# 先预览将匹配到什么（不写库，推荐第一次先看）
/usr/bin/python3 ~/.omniplay-douban-sync/douban_sync.py --dry-run

# 真实执行
/usr/bin/python3 ~/.omniplay-douban-sync/douban_sync.py --once

# 忽略冷却期强制重试（刚才没搜到/存疑的会重新试）
/usr/bin/python3 ~/.omniplay-douban-sync/douban_sync.py --once --force
```

> 首次全量同步因豆瓣 12s 限速，几十部片约需几分钟，正常现象。跑完后**重启一下觅影**即可看到绿色豆瓣徽章。

## 验证结果

同步后可直接查库确认：

```bash
sqlite3 ~/Library/Application\ Support/OmniPlay/omniplay.sqlite \
  "SELECT m.title, d.title, d.rating, d.ratingCount, m.posterPath
   FROM movie m LEFT JOIN doubanMetadata d ON d.movieId=m.id;"
```

## 遇到"搜不到/存疑"的片怎么办

无法自动判定的片**不会被写入**，原因会记录在：

```
~/.omniplay-douban-sync/review.tsv    # 格式: 片名 → 原因 → 豆瓣候选列表
~/.omniplay-douban-sync/sync.log      # 详细日志
```

处理方式（任选）：
1. **在觅影里手动绑定**（悬停海报 → 放大镜 → 绑定豆瓣条目）
2. 或用 `--force` 隔几天重试（可能是豆瓣接口瞬时限流）

## 豆瓣登录态 cookie（解锁「登录可见」条目）

豆瓣对**部分条目**做了「登录可见」限制——未登录时搜索结果为空、详情页返回
`404 你没有权限访问这个页面，请 登录 后重试`，内部 API 直接回
`{"msg": "need_permission"}`。这类片（例：《盲井》《天注定》）不配 cookie 永远同步不到。

配置方式：把浏览器里已登录豆瓣的 cookie 写入下面这个文件（**不要**写进 `config.json`，
那个文件会被同步到项目目录）：

```bash
umask 077; cat > ~/.omniplay-douban-sync/douban-cookie.txt
# 粘贴 cookie 值后按 Control-D
```

取值：Safari/Chrome 打开并登录 `douban.com` → `⌥⌘I` 网页检查器 → **存储(Storage)** 标签 →
左侧 Cookie → `https://www.douban.com` → 复制 `dbcl2`、`bid`、`ck`，拼成
`dbcl2="..."; bid=...; ck=...` 一行。网络标签的「请求标头 → Cookie」也可以。

要点：
- 文件权限 0600，只存本机，仅用于请求豆瓣；脚本从不外发。
- 不想用了直接删掉该文件，脚本自动退回未登录模式，其余片子不受影响。
- 未配 cookie 时脚本行为与之前完全一致。

### cookie 30 天就会过期，怎么办

**豆瓣的 `dbcl2` 是固定 30 天的令牌，服务端不会续期**（已实测 `www.douban.com`、
`movie.douban.com`、`m.douban.com`、个人页四个入口，均不下发新 cookie），浏览器也一样到期。
所以「长期有效」只能靠**降低对 cookie 的依赖**：

1. **已抓到的数据永久保留** —— 评分/海报存在本地 SQLite，cookie 过期**不会**清掉它们，
   受影响的只是「刷新」和「新增受限片」这两件事。
2. **过期时会有明确提示**，不再是静默失败：
   - 同步日志（`sync.log` / `daemon.log`）出现 `⏸《片名》需登录可见（cookie 未配置或已过期）`
   - 同步器目录生成 **`！需要更新豆瓣cookie.txt`**，列出待处理的片；处理完自动删除
   - 受限条目进入 `gated_cooldown_days`（默认 30 天）长冷却，也**不会**再每 3 天重试刷屏
3. **补一次只要 5 秒**：复制好 cookie 后，双击项目目录里的

   ```
   更新豆瓣Cookie.command
   ```

   它会自动完成：读剪贴板 → 校验 → 写入 0600 → 重启守护进程 → 立刻重试所有影片 → 汇报结果。
   从此不用开终端。

> `dbcl2` 在浏览器里也是 30 天到期，也就是说浏览器每隔一个月也要重新登录豆瓣一次 ——
> 那时候顺手双击一下这个程序就行。

## 配置

**默认值就能跑，不需要配置文件。** 要改的话，在 `~/.omniplay-douban-sync/config.json`
里只写你想覆盖的键即可（路径支持 `~` 开头），可覆盖：

| 键 | 默认 | 说明 |
|---|---|---|
| `request_interval` / `jitter` | 12 / 5 | 豆瓣请求间隔(秒)，与觅影一致 |
| `poster_priority` | `douban` | `douban`=有豆瓣海报就换；`tmdb`=仅 TMDB 海报缺失时才用豆瓣 |
| `cache_days` | 30 | 豆瓣记录有效期，到期自动刷新评分 |
| `not_found_cooldown_days` | 7 | 新片搜不到的冷却天数 |
| `refresh_fail_cooldown_days` | 3 | 刷新失败的冷却天数 |
| `gated_cooldown_days` | 30 | 「需登录可见」条目失败后的冷却天数（与豆瓣 cookie 寿命对齐） |
| `watch_interval` / `startup_delay` | 3 / 12 | 守护进程轮询与启动等待 |
| `cookie_file` | `~/.omniplay-douban-sync/douban-cookie.txt` | 豆瓣登录态 cookie 路径（可选） |

> **改了 `douban_sync.py` 要重启守护进程**，Python 不会热重载：
> `kill $(pgrep -f "douban_sync.py --daemon")`，launchd 的 `KeepAlive` 会自动拉起新实例。

## 卸载

```bash
~/.omniplay-douban-sync/uninstall.sh
# 或项目目录里
cd douban-sync && ./uninstall.sh
```

会停止并移除守护进程、删除 LaunchAgent 与程序文件；`review.tsv`、`backups/` 默认保留（确认无误后可手动删除 `~/.omniplay-douban-sync`）。

## 常见问题

**Q: 这算不算 hack？会不会弄坏觅影？**
A: 觅影是开源软件、数据库在你本机、写入前自动备份。写入的字段与觅影自身绑定豆瓣时写入的完全一致，只是帮你把"手动逐条"变成"自动批量"。任何一步出错可随时用备份库还原或重装觅影（豆瓣记录不进去，手动绑即可）。

**Q: 关闭梯子还能用吗？**
A: 能。豆瓣是国内服务，直连即可，本工具与 TMDB/Cloudflare 反代完全无关。

**Q: 以后新加了电影会同步吗？**
A: 会。守护进程在每次觅影启动时自动跑一次，只处理"还没有豆瓣记录"的新片；已记录的到期（默认 30 天）会刷新评分。
