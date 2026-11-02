#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OmniPlay(觅影) 豆瓣评分 + 海报 自动同步器
=========================================
原理：觅影的海报卡片每次刷新都会实时查询本地 SQLite 的 doubanMetadata 表。
      本脚本自动完成两件事：
      1) 新增同步：对"还没有豆瓣记录"的影片，豆瓣搜索 -> 年份消歧 ->
         抓详情(评分/人数/简介/海报) -> 直写 doubanMetadata -> 换豆瓣海报
      2) 到期刷新：已有豆瓣记录且超过 nextRefreshAt 的影片，用其 subjectId
         重新抓取，更新评分/人数/简介（评分会随豆瓣变动而更新）

请求节奏与觅影自身一致：每次间隔 ≥12s + 3~8s 随机抖动，避免给对方服务器造成压力。

本脚本只在你自己的机器上操作你自己的数据库，等价于帮你在觅影里逐条绑定豆瓣。
数据库写入前自动备份。失败/无法判定的影片不会写入，记入 review 清单待人工。

用法：
  douban_sync.py --dry-run            # 预览（不写库、不动状态）
  douban_sync.py --once               # 执行一次（含到期刷新）
  douban_sync.py --once --force       # 忽略冷却期强制重试
  douban_sync.py --daemon             # 守护模式：监测觅影启动后自动同步
"""
import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------
PROCESS_PATTERN = "觅影.app/Contents/MacOS"
BASE_DIR = os.path.expanduser("~/.omniplay-douban-sync")
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
BACKUP_DIR = os.path.join(BASE_DIR, "backups")
REVIEW_FILE = os.path.join(BASE_DIR, "review.tsv")
STATE_FILE = os.path.join(BASE_DIR, "state.json")
LOCK_FILE = os.path.join(BASE_DIR, "sync.lock")
LOG_FILE = os.path.join(BASE_DIR, "sync.log")
# 登录态 cookie（仅本机 0600）。存在时请求自动携带，用于解锁"登录可见"的条目。
COOKIE_FILE = os.path.join(BASE_DIR, "douban-cookie.txt")

# 同步完成后发给运行中 App 的 Darwin 通知名（App 侧同名监听）
NOTIFY_NAME = b"com.omniplay.doubanSyncDone"
# 有「需登录可见」条目待处理时生成的提示文件（处理完自动删除）
GATED_NOTICE_FILE = os.path.join(BASE_DIR, "！需要更新豆瓣cookie.txt")

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/OmniPlay/omniplay.sqlite")
DEFAULT_CONFIG = {
    "db_path": DEFAULT_DB,
    "local_poster_dir": os.path.expanduser("~/Pictures/omniplay-posters"),  # 豆瓣海报本地缓存（绕开防盗链）
    # 与觅影一致：≥12s + 3~8s 抖动
    "request_interval": 12.0,
    "jitter": 5.0,
    "not_found_cooldown_days": 7,   # 新片搜不到 -> 冷却天数
    "refresh_fail_cooldown_days": 3,  # 到期刷新失败 -> 冷却天数
    "gated_cooldown_days": 30,      # 「需登录可见」条目失败 -> 冷却天数(豆瓣 cookie 有效期就 30 天，这里给足)
    "cache_days": 30,               # 豆瓣记录有效期，到期后自动刷新
    # 一部片最多试几个查询词（中文 -> 目录中文名 -> 英文 ...）。
    # 每多试一次就多一次 12s+ 请求，所以只在还没命中时才往后试，且总量封顶。
    "max_query_attempts": 3,
    "poster_priority": "douban",    # douban=有豆瓣海报就换; tmdb=TMDB 海报缺失时才用豆瓣
    "watch_interval": 3,            # 守护进程轮询秒数
    "startup_delay": 12,            # 检测到觅影启动后等待秒数(让其完成初始化)
    "cookie_file": COOKIE_FILE,     # 豆瓣登录态 cookie 文件路径（可选）
}

UA_IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
UA_DESKTOP = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")

# 与觅影源码 DoubanMetadata.isUsablePosterURL 保持一致
USABLE_POSTER_RE = re.compile(
    r"https?://[a-z0-9.]*doubanio\.com/view/photo/(s_ratio_poster|raw|l)/public/", re.I)

_PUNCT = "".join(chr(c) for c in range(0x2000, 0x2070)) + "·（）()《》〈〉「」『』【】《》,，。、；;：: -—–_&&/+.!?！？'\"‘’“”"


def norm_title(s: str) -> str:
    if not s:
        return ""
    s = s.lower()
    for ch in _PUNCT:
        s = s.replace(ch, "")
    s = s.replace(" ", "").replace("\u3000", "")
    return s


def log(msg: str):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    try:
        os.makedirs(BASE_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)


# ----------------------------------------------------------------------------
# 配置加载
# ----------------------------------------------------------------------------
def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except OSError:
        pass
    return cfg


# ----------------------------------------------------------------------------
# 网络请求（限速与觅影一致：≥12s + 抖动）
# ----------------------------------------------------------------------------
class DoubanClient:
    def __init__(self, cfg):
        self.cfg = cfg
        self._last = 0.0
        self.fail_streak = 0
        self.cookie = self._load_cookie(cfg)
        # 最近一次请求的失败原因：None / "gated" / "blocked" / "gone" / "other"
        self.last_error = None

    @staticmethod
    def _load_cookie(cfg):
        """读取登录态 cookie；文件不存在或为空则返回 None（按未登录模式运行）。"""
        path = cfg.get("cookie_file") or COOKIE_FILE
        try:
            with open(path, encoding="utf-8") as f:
                ck = f.read().strip()
        except OSError:
            return None
        if not ck:
            return None
        ck = re.sub(r"\s*\n\s*", " ", ck)
        # 容错：整行从 DevTools 复制时可能带 "cookie:" 前缀
        ck = re.sub(r"^\s*cookie\s*:\s*", "", ck, flags=re.I)
        return ck.strip() or None

    def _throttle(self):
        gap = self.cfg["request_interval"] + random.uniform(0, self.cfg["jitter"])
        wait = gap - (time.time() - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.time()

    def _open(self, url, ua):
        self._throttle()
        headers = {
            "User-Agent": ua,
            "Accept": "text/html,application/json,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": "https://movie.douban.com/",
        }
        if self.cookie:
            headers["Cookie"] = self.cookie
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = r.read()
                self.fail_streak = 0
                self.last_error = None
                return data
        except urllib.error.HTTPError as e:
            self.fail_streak += 1
            if e.code in (403, 429):
                # 403 = 条目级 need_permission（未登录/cookie 失效）或触发访问频率限制
                body = ""
                try:
                    body = e.read(200).decode("utf-8", "ignore")
                except Exception:
                    pass
                self.last_error = "gated" if "need_permission" in body else "blocked"
            elif e.code == 404:
                # 有 subjectId 却 404 —— 豆瓣对「登录可见」条目的表现就是这个
                self.last_error = "gone"
            else:
                self.fail_streak += 1
                self.last_error = "other"
            return None
        except Exception:
            self.fail_streak += 1
            self.last_error = "other"
            return None

    # ---- 搜索 ----
    def search(self, title: str):
        """
        豆瓣 subject_suggest 偶发返回空数组（瞬时限流），空结果等待后重试，
        避免把真有的片误判为"无此片"。基础间隔已 12s，重试额外 +8s。
        """
        url = "https://movie.douban.com/j/subject_suggest?q=" + urllib.parse.quote(title)
        for i in range(3):
            data = self._open(url, UA_DESKTOP)
            if data is None:
                time.sleep(3)
                continue
            try:
                items = json.loads(data.decode("utf-8"))
                if isinstance(items, list) and items:
                    return items
                if i < 2:
                    log(f"    搜索返回空(第{i+1}次)，等待重试 ...")
                    time.sleep(8)
            except Exception:
                time.sleep(2 * (i + 1))
        return []

    # ---- 移动版详情页 ----
    def detail(self, subject_id: str):
        url = f"https://m.douban.com/movie/subject/{subject_id}/"
        data = self._open(url, UA_IPHONE)
        if data is None:
            return {}
        html = data.decode("utf-8", errors="ignore")
        info = {}

        def meta(prop):
            m = re.search(r'itemprop="%s"[^>]*content="([^"]+)"' % re.escape(prop), html)
            if m:
                return m.group(1)
            m = re.search(r'content="([^"]+)"[^>]*itemprop="%s"' % re.escape(prop), html)
            return m.group(1) if m else None

        info["rating"] = meta("ratingValue")
        info["ratingCount"] = meta("reviewCount")
        m = re.search(r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"', html)
        if m:
            t = re.sub(r"\s*[-–—|]\s*(电影|剧集|电视剧|综艺|纪录片).*$", "", m.group(1)).strip()
            info["title"] = t
        m = re.search(r'<meta[^>]+name="description"[^>]+content="([^"]*)"', html)
        if m:
            # 移动版页面的 description 是「片名豆瓣评分：9.0 简介：<正文>」这种拼装串。
            # 评分本来就单独存了，详情页也会另起一行显示，所以这里把前缀洗掉，
            # 只留正文 —— 这样它能直接当简介用（TMDB 关闭后详情页就靠它）。
            s = m.group(1).strip()
            s = re.sub(r"^.*?豆瓣评分\s*[:：]?\s*[\d.]+\s*简介\s*[:：]\s*", "", s)
            info["summary"] = s or None
        return info


# ----------------------------------------------------------------------------
# SQLite
# ----------------------------------------------------------------------------
def connect_db(cfg):
    # 支持 config.json 里写 `~/...`（expanduser 不处理 "~user"，这里也不需要）
    path = os.path.expanduser(cfg["db_path"])
    if not os.path.exists(path):
        log(f"数据库不存在: {path}")
        return None
    conn = sqlite3.connect(path, timeout=15)
    conn.execute("PRAGMA busy_timeout=12000")
    return conn


def backup_db(cfg):
    """sqlite 在线安全备份，保留最近 8 份。"""
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        ts = time.strftime("%Y%m%d-%H%M%S")
        dst = os.path.join(BACKUP_DIR, f"omniplay-{ts}.sqlite")
        subprocess.run(["/usr/bin/sqlite3", os.path.expanduser(cfg["db_path"]),
                        f".backup '{dst}'"], check=True, capture_output=True)
        bks = sorted(f for f in os.listdir(BACKUP_DIR) if f.startswith("omniplay-"))
        for old in bks[:-8]:
            os.remove(os.path.join(BACKUP_DIR, old))
        log(f"已备份数据库 -> {dst}")
        return dst
    except Exception as e:
        log(f"备份失败(继续执行): {e}")
        return None


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            st = json.load(f)
    except OSError:
        st = {}
    for k in ("notfound", "refreshfail", "gated"):
        st.setdefault(k, {})
    return st


def save_state(st):
    try:
        os.makedirs(BASE_DIR, exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(st, f, ensure_ascii=False, indent=1)
    except OSError:
        pass


def acquire_lock():
    try:
        os.makedirs(BASE_DIR, exist_ok=True)
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        return None


# ----------------------------------------------------------------------------
# 资源名解析：从文件名 / 目录名里抽出「可能的片名」
#
# 思路借鉴 guessit（tinyMediaManager、MoviePilot、Radarr/Sonarr 都在用）：
# 把文件名切成 token，按词表把「技术标签」（来源/分辨率/编码/音轨/发布组）
# 摘掉，剩下的连续片段就是片名。
#
# 为什么不用 guessit 本身：它依赖 rebulk + python-dateutil 两个第三方包，而本
# 守护进程跑在系统自带的 /usr/bin/python3（3.9.6）上、刻意保持**零依赖**
# （launchd 直接起脚本，装包会破坏「单文件可拷贝」这个前提）。
# 所以只吸收它的「词表 + 切分」思想，不引入依赖。
# ----------------------------------------------------------------------------

# 技术标签词表（拉丁文，比较时已归一化为小写字母数字）。取自 guessit 的
# source / screenSize / videoCodec / audioCodec / other 五类词表，按常见
# 发布组命名裁剪。用正则兜住「词根 + 数字」的变体（ddp5 / h265 / ac3 等）。
_TECH_WORDS = {
    # 来源
    "bluray", "blu", "ray", "bdrip", "brrip", "bdremux", "remux", "dvdrip", "dvdscr",
    "dvd", "hdrip", "hdtv", "webrip", "webdl", "web", "uhd", "hd", "sd", "cam",
    "ts", "tc", "r5", "vhs", "vcd", "ppv", "vod", "dvb", "hdvd",
    # 分辨率
    "4k", "8k", "uhd", "fhd", "qhd",
    # 视频编码 / 规格
    "hevc", "avc", "xvid", "divx", "mpeg", "mpeg2", "vp9", "av1", "hi10p",
    "bit", "fps", "hdr", "hdr10", "dv", "sdr", "imax", "cc", "criterion",
    # 音频
    "dts", "dtshd", "truehd", "atmos", "flac", "mp3", "lpcm", "pcm", "ma", "hdma",
    "multi", "dualaudio", "dual", "audios", "audio", "chs", "cht", "eng", "chi", "jpn",
    # 版本
    "repack", "proper", "internal", "extended", "unrated", "remastered", "complete",
}
# 「词根 + 可选数字」的变体：h264 / h265 / x264 / x265 / aac / ac3 / eac3 / dd5 / ddp51 ...
_TECH_VARIANT_RE = re.compile(
    r"^(?:aac|ac3|eac3|dd|ddp|dts|dtshd|truehd|atmos|flac|mp3|lpcm|pcm|"
    r"h|x|avc|hevc|xvid|divx|mpeg)\d*$")

# 中文技术标签：命中这些词的纯中文片段不当片名（「简繁中字」「国粤日三语」等）
_CN_TAG_HINTS = ("中字", "字幕", "简体", "繁体", "简繁", "国语", "粤语", "双语", "三语",
                 "国配", "台配", "港配", "原声", "配音", "高清", "蓝光", "修复", "重制",
                 "加长", "未删", "完整版", "导演", "剪辑", "内嵌", "外挂", "公映")

# 连续中文片段（允许名字中间夹 · 或 ・，如「本杰明·巴顿奇事」）
_CJK_RUN_RE = re.compile(u"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]"
                         u"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u00b7\u30fb]*")
_CJK_RE = re.compile(u"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
_YEAR_RE = re.compile(r"^(?:19|20)\d{2}$")
# 容器后缀。不剥掉的话 `The.Matrix.1999.mkv` 会把 mkv 当成片名的一部分。
_EXT_RE = re.compile(r"\.(?:mkv|mp4|m4v|avi|mov|m2ts|ts|wmv|flv|webm|rmvb|rm|mpg|mpeg|"
                     r"iso|divx|vob|ogm|ogv|3gp|srt|ass|ssa|sub|idx)$", re.I)


def _tokenize(text):
    """把文件名/目录名切成 token（按 . _ 空格 及各类括号分隔）。"""
    return [t for t in re.split(r"[.\s_\[\]【】()（）{}]+", text) if t]


def _is_cn_tag(run):
    return any(h in run for h in _CN_TAG_HINTS)


def cjk_candidates(text):
    """按出现顺序返回 text 里「像片名」的中文片段（先非标签词，后标签词兜底）。

    紧跟在拉丁字母后面的中文片段一律丢掉——那是发布组的中文名，
    例如 `CMCT子龍` / `CMCT风潇潇` / `1080p简繁中字`。
    """
    text = text or ""
    runs = []
    for m in _CJK_RUN_RE.finditer(text):
        if m.start() > 0:
            prev = text[m.start() - 1]
            if prev.isascii() and prev.isalpha():
                continue
        r = m.group(0).strip("\u00b7\u30fb")
        if len(r) >= 2:
            runs.append(r)
    if not runs:
        return []
    return [r for r in runs if not _is_cn_tag(r)] or runs


def _is_tech(tok):
    key = re.sub(r"[^0-9a-z]", "", tok.lower())
    if not key or _YEAR_RE.match(key):
        return False
    if key.isdigit():            # 5 / 7 / 1（来自 5.1、7.1）
        return True
    head = key.lstrip("0123456789")   # 2Audios / 3Audios
    for k in (key, head):
        if k and (k in _TECH_WORDS or _TECH_VARIANT_RE.match(k)):
            return True
    return bool(re.fullmatch(r"\d+(?:p|i|bit|fps|k)", key))


def _pick_year_index(tokens):
    """在 token 里挑出年份的位置。取「后面技术标签最多」的那个，平票取靠后的。
    这样 `2012.2009.BluRay...` 会选中 2009（片名是 2012），不是 2012。"""
    best, best_score = None, -1
    for i, t in enumerate(tokens):
        if not _YEAR_RE.match(t):
            continue
        score = sum(1 for x in tokens[i + 1:] if _is_tech(x))
        if score >= best_score:
            best, best_score = i, score
    return best


def latin_candidates(text):
    """从文件名/目录名里抽出可能的英文片名（年份前一段为主，年份后一段为辅）。"""
    tokens = _tokenize(_EXT_RE.sub("", text or ""))
    if tokens:
        # 发布组总在末尾：AC3-CMCT / AAC-FFans@qszS -> 只留前半个 token
        last = tokens[-1]
        if "-" in last or "@" in last:
            tokens[-1] = re.split(r"[-@]", last)[0]
    yi = _pick_year_index(tokens)
    if yi is None:
        return []
    out = []
    for idx, seg in enumerate((tokens[:yi], tokens[yi + 1:])):
        words = []
        for t in seg:
            if _is_tech(t):
                if idx == 1 and words:
                    break        # 年份之后遇到技术标签即止（后面全是参数）
                continue
            if _CJK_RE.search(t):
                continue         # 中英混排只取英文那半（《无间道》Infernal.Affairs）
            words.append(t)
        name = " ".join(words).strip()
        if len(name) >= 2:
            out.append(name)
    return out


def build_query_candidates(db_title, file_name, folder_name, movie_year):
    """按可信度排序的查询词候选（已归一化去重）。

    顺序遵循用户要求「先用中文搜」：文件名里的中文片名 -> 目录名的中文片名 ->
    库里已有标题（若已是干净中文）-> 英文片名 -> 带年份的中文名 -> 库标题清洗版。
    目录名常常比文件名干净（如「盲井.2003.简繁中字」），所以也纳入候选。
    """
    cands = []
    cands += cjk_candidates(file_name)
    cands += cjk_candidates(folder_name)
    if db_title and _CJK_RE.search(db_title) and not any(_is_tech(t) for t in _tokenize(db_title)):
        cands += cjk_candidates(db_title)
    cands += latin_candidates(file_name)
    cands += latin_candidates(folder_name)
    prime = cjk_candidates(file_name) or cjk_candidates(folder_name) or []
    if prime and movie_year:
        cands.append(f"{prime[0]} {movie_year}")
    if db_title:
        cands.append(db_title)

    seen, out = set(), []
    for c in cands:
        c = (c or "").strip()
        if not c:
            continue
        k = norm_title(c)
        if not k or k in seen:
            continue
        seen.add(k)
        out.append(c)
    return out


# ----------------------------------------------------------------------------
# 匹配
# ----------------------------------------------------------------------------
def pick_best(items, movie_title, movie_year):
    """从豆瓣搜索结果里挑最可信的一条。返回 (chosen, reason)。"""
    movies = [it for it in items if it.get("type") == "movie"]
    if not movies:
        return None, "nomatch"
    nt = norm_title(movie_title)
    exact = [it for it in movies if norm_title(it.get("title")) == nt]
    pool = exact if exact else movies
    if not pool:
        return None, "nomatch"

    if len(pool) == 1:
        return pool[0], "ok"

    # 多个同名候选 -> 年份消歧
    if movie_year:
        scored = []
        for it in pool:
            try:
                dyear = int(re.search(r"\d{4}", str(it.get("year", ""))).group())
            except Exception:
                dyear = None
            scored.append((it, dyear))
        with_year = [(it, d) for it, d in scored if d is not None]
        if with_year:
            with_year.sort(key=lambda x: abs(x[1] - movie_year))
            best, best_y = with_year[0]
            second = with_year[1] if len(with_year) > 1 else None
            if second is None or abs(best_y - movie_year) < abs(second[1] - movie_year):
                if abs(best_y - movie_year) <= 2:
                    return best, "ok"
                return None, "ambiguous"
            return None, "ambiguous"

    if len(pool) > 1 and norm_title(pool[0].get("title")) == norm_title(pool[1].get("title")):
        return None, "ambiguous"
    return pool[0], "ok"


def _download_to_local(url, movie_id, cfg):
    """把豆瓣海报下载到本地目录，返回绝对路径。失败时返回原 URL。"""
    if not cfg.get("local_poster_dir"):
        return url
    if "doubanio.com" not in url:
        return url  # 仅对豆瓣图床启用本地缓存（TMDB 无防盗链问题）
    local_dir = os.path.expanduser(cfg["local_poster_dir"])
    try:
        os.makedirs(local_dir, exist_ok=True)
    except OSError as e:
        log(f"  ⚠ 无法创建海报目录 {local_dir}: {e}")
        return url
    # 文件名: douban_<movieId>.jpg（用 movieId 保证唯一）
    ext = "jpg"
    if "." in url.split("/")[-1]:
        ext = url.split("/")[-1].rsplit(".", 1)[-1].lower()
        if ext not in ("jpg", "jpeg", "png", "webp"):
            ext = "jpg"
    fname = f"douban_{movie_id}.{ext}"
    local_path = os.path.join(local_dir, fname)
    if os.path.exists(local_path) and os.path.getsize(local_path) > 1024:
        return local_path  # 已缓存，直接用
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": UA_IPHONE,
            "Referer": "https://movie.douban.com/",
        })
        with urllib.request.urlopen(req, timeout=20) as r:
            if r.status != 200:
                return url
            data = r.read()
            if len(data) < 1024:  # 豆瓣偶尔返回 1xx 字节的占位
                return url
            with open(local_path, "wb") as f:
                f.write(data)
            return local_path
    except Exception as e:
        log(f"  ⚠ 海报下载失败: {e}")
    return url  # 兜底用 URL（虽然 App 那边还是会 418）


def build_poster_url(img, movie_id=None, cfg=None):
    """s_ratio_poster → 升级 l 大图 → 豆瓣图床下载到本地。
    返回本地绝对路径（如 ~/Pictures/omniplay-posters/douban_3.jpg）或原 URL（非 douban）。"""
    if not img:
        return None
    m = re.match(r"(https?://[a-z0-9.]*doubanio\.com/view/photo/)s_ratio_poster(/public/[^/]+\.(?:jpg|png|webp))", img, re.I)
    if m:
        url = m.group(1) + "l" + m.group(2)
    elif USABLE_POSTER_RE.search(img):
        url = img
    else:
        return None
    if cfg is not None:
        return _download_to_local(url, movie_id, cfg)
    return url


# ----------------------------------------------------------------------------
# 主同步
# ----------------------------------------------------------------------------
def run_sync(cfg, dry_run=False, force=False):
    lockfd = acquire_lock()
    if lockfd is None:
        log("另一个同步实例正在运行，跳过")
        return
    try:
        _sync(cfg, dry_run, force)
    finally:
        os.close(lockfd)


def _parse_year(rdate):
    if rdate:
        mm = re.search(r"(\d{4})", str(rdate))
        if mm:
            return int(mm.group(1))
    return None


def _sync(cfg, dry_run, force):
    conn = connect_db(cfg)
    if conn is None:
        return
    try:
        st = load_state()
        now = time.time()
        nf_cd = cfg["not_found_cooldown_days"] * 86400
        rf_cd = cfg["refresh_fail_cooldown_days"] * 86400
        gd_cd = cfg["gated_cooldown_days"] * 86400
        client = DoubanClient(cfg)

        # 待处理：无豆瓣记录(新) 或 已过期(需刷新)
        # 顺带取一个视频文件名和它所在的目录名：库里 title 可能是「文件名直入」的
        # 脏值，而 videoFile.fileName / 父目录名才是原始资源名——《盲井》就是这么救的。
        # 子查询的 ORDER BY 让本地扫描的文件优先于「访达直开」/ Docker 条目。
        rows = conn.execute(
            "SELECT m.id, m.title, m.releaseDate, m.isLocked, m.posterPath, "
            "       d.subjectURL, d.nextRefreshAt, "
            "       (SELECT vf.fileName FROM videoFile vf WHERE vf.movieId = m.id "
            "         ORDER BY (vf.id LIKE 'omniplay-docker:%') LIMIT 1), "
            "       (SELECT vf.relativePath FROM videoFile vf WHERE vf.movieId = m.id "
            "         ORDER BY (vf.id LIKE 'omniplay-docker:%') LIMIT 1) "
            "FROM movie m LEFT JOIN doubanMetadata d ON d.movieId = m.id "
            "WHERE d.movieId IS NULL OR d.nextRefreshAt < ? "
            "ORDER BY m.title", (now,)
        ).fetchall()

        max_q = max(1, int(cfg.get("max_query_attempts", 3)))

        to_new, to_refresh, gated_wait = [], [], []
        for mid, title, rdate, locked, old_poster, sub_url, nra, file_name, rel_path in rows:
            if not title:
                continue
            # 锁定态只作"别覆盖已有海报"用，不再跳过整部片（否则手动加/被锁的片永远拿不到豆瓣分）
            mid_key = str(mid)
            # 「需登录可见」条目：冷却期内不重试；未配置 cookie 时连请求都不发
            if not force and mid_key in st["gated"] and now - st["gated"][mid_key] < gd_cd:
                gated_wait.append(title)
                continue
            if sub_url is None:  # 新片
                if not force and mid_key in st["notfound"] and now - st["notfound"][mid_key] < nf_cd:
                    continue
                folder = os.path.basename(os.path.dirname(rel_path or ""))
                to_new.append((mid, title, rdate, locked, old_poster, file_name or "", folder))
            else:                # 到期刷新
                if not force and mid_key in st["refreshfail"] and now - st["refreshfail"][mid_key] < rf_cd:
                    continue
                m = re.search(r"/subject/(\d+)", sub_url or "")
                if not m:
                    continue
                to_refresh.append((mid, title, m.group(1), sub_url))

        if gated_wait:
            hint = ("（当前未配置 cookie，配好后会自动重试）" if client.cookie is None
                    else "（cookie 可能已过期，重新配置后会自动重试）")
            log(f"⏸ {len(gated_wait)} 部需登录可见，冷却中："
                f"{'、'.join(gated_wait[:5])} {hint}")

        if not to_new and not to_refresh:
            log("没有待同步/待刷新的影片（豆瓣记录已齐全且未到期）")
            return
        log(f"待处理：新增 {len(to_new)} 部，到期刷新 {len(to_refresh)} 部")

        chosen_new = []       # (mid,title,rdate,cand,detail,locked,old_poster)
        refreshed = []        # (mid,title,sid,detail,oldrating)
        not_found = []
        ambiguous = []
        gated_fail = []       # (mid,title) 条目本身「需登录可见」（cookie 缺失/过期）
        net_blocked = False

        # ---------- 1) 新片搜索匹配 ----------
        for mid, title, rdate, locked, old_poster, file_name, folder in to_new:
            if net_blocked or client.fail_streak >= 4:
                net_blocked = True
                not_found.append((mid, title, "豆瓣限流，本轮未处理"))
                continue
            movie_year = _parse_year(rdate)
            # 一个片名试不出来就换下一个形态（中文 -> 目录中文名 -> 英文 -> 中文+年份）
            queries = build_query_candidates(title, file_name, folder, movie_year)
            total = min(len(queries), max_q)
            cand, used, last_items = None, None, []
            for qi, q in enumerate(queries[:total]):
                log(f"  搜索《{q}》({movie_year or '?'}) [{qi+1}/{total}] ...")
                items = client.search(q)
                if client.fail_streak >= 4:
                    net_blocked = True
                    break
                if not items:
                    continue
                if not last_items:
                    last_items = items          # 留作 review 参考
                c, reason = pick_best(items, q, movie_year)
                if reason == "ok" and c is not None:
                    cand, used = c, q
                    break
                log(f"    未采信（{reason}），换下一个候选词 ...")
            if net_blocked or client.fail_streak >= 4:
                net_blocked = True
                not_found.append((mid, title, "豆瓣限流，本轮未处理"))
                continue
            if cand is None:
                if not last_items:
                    # 未配 cookie 时，无法区分"豆瓣真没这片"和"豆瓣对未登录隐藏了它"
                    not_found.append((mid, title, "豆瓣无此片" if client.cookie
                                      else "豆瓣搜不到（未配置 cookie）"))
                else:
                    cands = " | ".join(f"{it.get('title')}({it.get('year')},id={it.get('id')})"
                                       for it in last_items[:6])
                    ambiguous.append((mid, title,
                                      "候选词均未采信: " + " / ".join(queries[:total]), cands))
                continue

            detail = client.detail(cand.get("id", ""))
            if net_blocked or client.fail_streak >= 4:
                net_blocked = True
                not_found.append((mid, title, "豆瓣限流，本轮未处理"))
                continue
            if not detail.get("rating") and not detail.get("title"):
                if client.last_error in ("gated", "gone"):
                    gated_fail.append((mid, title))
                    log(f"    ⏸《{title}》需登录可见（cookie 未配置或已过期）")
                else:
                    ambiguous.append((mid, title, "详情页解析失败", cand.get("title", "")))
                continue
            chosen_new.append((mid, title, rdate, cand, detail, locked, old_poster))
            log(f"    → 匹配《{cand.get('title')}》({cand.get('year')}, id={cand.get('id')}) "
                f"评分={detail.get('rating') or '无'} 人数={detail.get('ratingCount') or '?'}"
                f"  命中查询词：{used}")

        # ---------- 2) 到期刷新（按已有 subjectId） ----------
        for mid, title, sid, sub_url in to_refresh:
            if net_blocked or client.fail_streak >= 4:
                net_blocked = True
                refreshed.append((mid, title, sid, None, None))
                continue
            log(f"  刷新《{title}》(subject {sid}) ...")
            detail = client.detail(sid)
            if net_blocked or client.fail_streak >= 4:
                net_blocked = True
                refreshed.append((mid, title, sid, None, None))
                continue
            if not detail.get("rating") and not detail.get("title"):
                if client.last_error in ("gated", "gone"):
                    # 豆瓣要求登录态 —— 不是网络抖动，别用普通冷却反复重试刷屏
                    gated_fail.append((mid, title))
                    log(f"    ⏸《{title}》需登录可见（cookie 未配置或已过期）"
                        f"→ 保留库中已有评分")
                else:
                    refreshed.append((mid, title, sid, None, None))
                    log(f"    ⚠《{title}》详情获取失败（{client.last_error or '解析失败'}）")
                continue
            refreshed.append((mid, title, sid, detail, None))
            log(f"    → 刷新后评分={detail.get('rating') or '无'} "
                f"人数={detail.get('ratingCount') or '?'}")

        # ---------- 预览 ----------
        if dry_run:
            log("=== dry-run 预览结束 ===")
            if chosen_new:
                for mid, title, rdate, cand, detail, _locked, _old_poster in chosen_new:
                    print(f"  [✔ 新增] {title} → 《{cand.get('title')}》({cand.get('year')}) "
                          f"评分 {detail.get('rating') or '无'}  人数 {detail.get('ratingCount') or '?'}")
            if refreshed:
                for mid, title, sid, detail, _old in refreshed:
                    if detail:
                        print(f"  [↻ 刷新] {title} → 评分 {detail.get('rating') or '无'}  "
                              f"人数 {detail.get('ratingCount') or '?'}")
                    else:
                        print(f"  [↻ 刷新受限/失败] {title}")
            if ambiguous:
                print("  [⚠ 无法判定，跳过]")
                for mid, title, reason, cands in ambiguous:
                    print(f"      {title} -> {reason}: {cands}")
            if not_found:
                print("  [✖ 未找到/受限]")
                for mid, title, reason in not_found:
                    print(f"      {title} -> {reason}")
            log(f"dry-run 结束：{len(chosen_new)} 可新增，{len(refreshed)} 可刷新，"
                f"{len(ambiguous)} 存疑，{len(not_found)} 未找到")
            return

        # ---------- 真实执行 ----------
        if chosen_new or any(r[3] for r in refreshed):
            backup_db(cfg)
        wrote = 0
        for mid, title, rdate, cand, detail, locked, old_poster in chosen_new:
            subject_id = cand.get("id", "")
            subject_url = f"https://movie.douban.com/subject/{subject_id}/"
            rating = None
            try:
                rating = float(detail.get("rating"))
            except (TypeError, ValueError):
                pass
            rating_count = None
            try:
                rating_count = int(detail.get("ratingCount"))
            except (TypeError, ValueError):
                pass
            summary = (detail.get("summary") or "")[:2000] or None
            poster = build_poster_url(cand.get("img"), mid, cfg)
            year = cand.get("year") or (str(rdate)[:4] if rdate else None)
            fetched = time.time()
            next_refresh = fetched + cfg["cache_days"] * 86400
            try:
                conn.execute(
                    "INSERT OR REPLACE INTO doubanMetadata "
                    "(movieId, subjectId, subjectURL, title, originalTitle, year, rating, "
                    " ratingCount, summary, genres, countries, directors, casts, posterURL, "
                    " fetchedAt, nextRefreshAt, lastError) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (mid, subject_id, subject_url,
                     detail.get("title") or cand.get("title"), None, year,
                     rating, rating_count, summary, None, None, None, None,
                     poster, fetched, next_refresh, None))
                # 锁定过的影片只补数据、不覆盖已有海报
                if poster and cfg["poster_priority"] == "douban" and not (locked and old_poster):
                    conn.execute("UPDATE movie SET posterPath=? WHERE id=?", (poster, mid))
                wrote += 1
                log(f"  ✔ 写入《{title}》 豆瓣分 {rating} ({rating_count}人)")
            except sqlite3.Error as e:
                log(f"  ✖ 写入失败《{title}》: {e}")

        # 刷新：更新评分/人数/简介/到期时间
        refresh_ok = 0
        for mid, title, sid, detail, _old in refreshed:
            if not detail:
                continue
            rating = None
            try:
                rating = float(detail.get("rating"))
            except (TypeError, ValueError):
                pass
            rating_count = None
            try:
                rating_count = int(detail.get("ratingCount"))
            except (TypeError, ValueError):
                pass
            summary = (detail.get("summary") or "")[:2000] or None
            next_refresh = time.time() + cfg["cache_days"] * 86400
            try:
                conn.execute(
                    "UPDATE doubanMetadata SET rating=?, ratingCount=?, summary=?, "
                    "posterURL=COALESCE(posterURL, ?), nextRefreshAt=?, lastError=NULL "
                    "WHERE movieId=?",
                    (rating, rating_count, summary, None, next_refresh, mid))
                refresh_ok += 1
                log(f"  ↻ 刷新《{title}》 评分 {rating} ({rating_count}人)")
            except sqlite3.Error as e:
                log(f"  ✖ 刷新失败《{title}》: {e}")
        conn.commit()

        # ---------- 状态与 review ----------
        if ambiguous:
            try:
                existing = set()
                if os.path.exists(REVIEW_FILE):
                    with open(REVIEW_FILE, encoding="utf-8") as f:
                        existing = set(line.split("\t")[0] for line in f if "\t" in line)
                with open(REVIEW_FILE, "a", encoding="utf-8") as f:
                    for mid, title, reason, cands in ambiguous:
                        if title not in existing:
                            f.write(f"{title}\t{reason}\t{cands}\n")
                            existing.add(title)
                log(f"⚠ {len(ambiguous)} 部无法自动判定，已记入 {REVIEW_FILE}")
            except OSError as e:
                log(f"review 清单写入失败: {e}")

        new_nf = dict(st["notfound"])
        new_rf = dict(st["refreshfail"])
        new_gated = dict(st["gated"])
        chosen_mids = {str(mid) for mid, *_ in chosen_new}
        # 成功拿到详情的（新增 + 刷新）—— 这些要从各种冷却名单里清掉
        ok_mids = chosen_mids | {str(mid) for mid, _t, _s, d, _o in refreshed if d}
        for mid in list(new_nf):
            if mid in chosen_mids:
                del new_nf[mid]
        for mid, *_ in not_found:
            new_nf[str(mid)] = now
        for mid in list(new_rf):
            if mid in ok_mids:
                del new_rf[mid]
        # 刷新失败且非网络限流的 -> 记冷却；网络限流不记（下轮自动再试）
        for mid, title, sid, detail, _old in refreshed:
            if detail is None and str(mid) not in ok_mids:
                new_rf[str(mid)] = now
        # 「需登录可见」-> 长冷却（默认 30 天，与豆瓣 cookie 寿命对齐），成功取到即清除
        for mid in list(new_gated):
            if mid in ok_mids:
                del new_gated[mid]
        for mid, _title in gated_fail:
            new_gated[str(mid)] = now
        st["notfound"] = new_nf
        st["refreshfail"] = new_rf
        st["gated"] = new_gated
        save_state(st)

        # 需要人工处理时留一个显眼的提示文件；不再需要时自动删除
        pending = sorted({t for _m, t in gated_fail} | set(gated_wait))
        if pending:
            try:
                with open(GATED_NOTICE_FILE, "w", encoding="utf-8") as f:
                    f.write("这些影片在豆瓣属于「登录可见」条目，需要登录态 cookie 才能获取/刷新：\n\n")
                    for n in pending:
                        f.write(f"  - {n}\n")
                    f.write("\n库中已有的评分不会被清除，只是暂停刷新。\n"
                            "处理办法：重新取一次 cookie（见 README「豆瓣登录态 cookie」一节），\n"
                            f"写入 {COOKIE_FILE} 即可，下一轮同步会自动恢复。\n")
                log(f"⏸ 需登录可见 {len(pending)} 部：{'、'.join(pending[:5])}"
                    f" → 已生成提示文件 {os.path.basename(GATED_NOTICE_FILE)}")
            except OSError as e:
                log(f"提示文件写入失败: {e}")
        else:
            try:
                os.remove(GATED_NOTICE_FILE)
            except OSError:
                pass

        log(f"同步完成：新增写入 {wrote}，刷新 {refresh_ok}，"
            f"存疑 {len(ambiguous)}，未找到 {len(not_found)}，需登录 {len(gated_fail)}")
        # 通知 App 立即刷新海报墙，不等它自己的 15s 轮询。
        # App 是另一个进程，NotificationCenter 跨不了进程，故用 Darwin 通知。
        if wrote or refresh_ok:
            notify_app_refresh()
    finally:
        conn.close()


def notify_app_refresh():
    """用 Darwin 通知喊一声，让运行中的觅影立刻重读豆瓣元数据。

    为什么需要：App 用 GRDB 的 DatabaseQueue（不是 ValueObservation），
    外部进程直接改 sqlite 它完全感知不到，界面会一直停在空占位
    （实测：评分和海报文件都已入库，界面仍是空白，必须重启 App）。

    为什么用 notifyutil 而不是 ctypes 直调 CFNotificationCenter：
    手写 ctypes 传 CFString 指针会段错误（实测 exit 139，两种签名都崩），
    参数对不齐很难调对。/usr/bin/notifyutil -p 是系统自带工具，行为可靠。
    """
    try:
        subprocess.run(["/usr/bin/notifyutil", "-p", NOTIFY_NAME.decode()],
                       check=True, capture_output=True, timeout=5)
    except Exception as e:
        # 通知失败不影响同步结果，只是界面要等 15s 轮询
        log(f"  （通知 App 刷新失败：{e}，界面将在 15s 轮询后自动更新）")


# ----------------------------------------------------------------------------
# 守护模式：监测觅影进程启动
# ----------------------------------------------------------------------------
def app_running():
    try:
        r = subprocess.run(["pgrep", "-f", PROCESS_PATTERN],
                           capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False


def run_daemon(cfg):
    log(f"守护进程启动，轮询间隔 {cfg['watch_interval']}s；"
        f"觅影关闭后同步(主)，启动后兜底补一次")
    was = None
    while True:
        cur = app_running()
        if was is None:
            # 守护刚启动：趁觅影未运行先补一次同步（覆盖上次关机前的遗漏）
            if not cur:
                run_sync(cfg, dry_run=False, force=False)
            else:
                time.sleep(cfg["startup_delay"])
                run_sync(cfg, dry_run=False, force=False)
            was = cur
            continue
        if was is True and cur is False:
            # 关闭边沿（主路径）：趁 App 未运行写库，下次打开即可直接看到
            log("检测到觅影关闭，等待其完全退出后同步 ...")
            time.sleep(5)
            run_sync(cfg, dry_run=False, force=False)
        elif was is False and cur is True:
            # 启动边沿（兜底）：处理同步失败/收到新片但未触发关闭边沿的情况
            log("检测到觅影启动，等待初始化后同步 ...")
            time.sleep(cfg["startup_delay"])
            run_sync(cfg, dry_run=False, force=False)
        was = cur
        time.sleep(cfg["watch_interval"])


# ----------------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------------
def main():
    args = [a for a in sys.argv[1:]]
    cfg = load_config()

    if "--db" in args:
        i = args.index("--db")
        cfg["db_path"] = os.path.expanduser(args[i + 1])
    if "--poster-tmdb" in args:
        cfg["poster_priority"] = "tmdb"
    if "--poster-douban" in args:
        cfg["poster_priority"] = "douban"

    dry = "--dry-run" in args
    force = "--force" in args

    if "--daemon" in args:
        run_daemon(cfg)
    elif "--once" in args or dry:
        run_sync(cfg, dry_run=dry, force=force)
    else:
        print(__doc__)
        print("用法示例：")
        print("  douban_sync.py --dry-run            # 预览")
        print("  douban_sync.py --once               # 执行一次(含刷新)")
        print("  douban_sync.py --once --force       # 忽略冷却重试")
        print("  douban_sync.py --daemon             # 守护模式")


if __name__ == "__main__":
    main()
