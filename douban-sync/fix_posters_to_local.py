#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性修复：将已有 doubanMetadata 记录的影片海报下载到本地并改写数据库。

背景：觅影 PosterManager 下载豆瓣海报时用 URLSession.shared.data(from:) 裸加载，
       豆瓣图床返回 418 防盗链。修复路径：把 douban 海报存到本地，posterPath 改
       本地绝对路径，觅影会走「hasPrefix("/") 本地文件」分支直接读取。

仅处理当前数据库里 posterPath 仍是 URL 的影片。幂等可重跑。
"""
import json, os, sys, sqlite3, urllib.request

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/OmniPlay/omniplay.sqlite")
LOCAL_DIR = os.path.expanduser("~/Pictures/omniplay-posters")
UA_IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

def download(url, dest_path):
    """带 Referer 下载到本地。返回写入字节数或 0（失败）。"""
    req = urllib.request.Request(url, headers={
        "User-Agent": UA_IPHONE,
        "Referer": "https://movie.douban.com/",
    })
    with urllib.request.urlopen(req, timeout=20) as r:
        if r.status != 200:
            return 0
        data = r.read()
        if len(data) < 1024:
            return 0
        with open(dest_path, "wb") as f:
            f.write(data)
        return len(data)

def main():
    db_path = DEFAULT_DB
    for i, a in enumerate(sys.argv):
        if a == "--db" and i + 1 < len(sys.argv):
            db_path = os.path.expanduser(sys.argv[i + 1])

    if not os.path.exists(db_path):
        print(f"数据库不存在: {db_path}"); return 1

    os.makedirs(LOCAL_DIR, exist_ok=True)
    print(f"海报目录: {LOCAL_DIR}")
    print(f"数据库:   {db_path}\n")

    conn = sqlite3.connect(db_path, timeout=15)
    conn.execute("PRAGMA busy_timeout=12000")

    # 找当前 doubanMetadata 已有但 posterPath 仍是 URL 的影片
    rows = conn.execute("""
        SELECT m.id, m.title, m.posterPath, d.posterURL
        FROM movie m
        JOIN doubanMetadata d ON d.movieId = m.id
        WHERE (m.posterPath LIKE 'http%' OR m.posterPath IS NULL)
              AND d.posterURL LIKE '%doubanio.com%'
    """).fetchall()

    if not rows:
        print("✅ 没有需要修复的影片（posterPath 已是本地路径或无豆瓣记录）")
        conn.close()
        return 0

    print(f"待修复: {len(rows)} 部\n")
    fixed, failed = 0, []

    for mid, title, cur_path, dou_url in [(r[0], r[1], r[2], r[3]) for r in rows]:
        # 本地文件名: douban_<movieId>.jpg
        ext = "jpg"
        if dou_url and "." in dou_url.split("/")[-1]:
            cand = dou_url.split("/")[-1].rsplit(".", 1)[-1].lower()
            if cand in ("jpg", "jpeg", "png", "webp"):
                ext = cand
        local_path = os.path.join(LOCAL_DIR, f"douban_{mid}.{ext}")

        # 已下载就跳过下载，但确保数据库正确
        if os.path.exists(local_path) and os.path.getsize(local_path) > 1024:
            sz = os.path.getsize(local_path)
            print(f"  ✓ 已缓存 《{title}》  -> {local_path} ({sz} 字节)")
        else:
            print(f"  ↓ 下载 《{title}》  <- {dou_url[:70]}...")
            sz = download(dou_url, local_path)
            if sz == 0:
                failed.append((title, dou_url))
                print(f"    ✖ 下载失败")
                continue
            print(f"    ✔ {sz} 字节已保存 -> {local_path}")

        # 改数据库: posterPath 改为本地绝对路径
        try:
            conn.execute("UPDATE movie SET posterPath=? WHERE id=?", (local_path, mid))
            fixed += 1
            print(f"    📝 movie.posterPath 已改为本地路径\n")
        except sqlite3.Error as e:
            failed.append((title, str(e)))
            print(f"    ✖ 数据库写入失败: {e}\n")

    conn.commit()
    conn.close()

    print(f"\n===== 修复完成 =====")
    print(f"成功: {fixed}/{len(rows)}  失败: {len(failed)}")
    if failed:
        print("失败列表：")
        for t, u in failed:
            print(f"  - 《{t}》 {u}")
        print("\n请重启觅影 App（Cmd+Q 后再打开），海报墙就会显示本地缓存的海报。")
        return 1
    print("\n请重启觅影 App（Cmd+Q 后再打开），海报墙就会显示本地缓存的海报。")
    return 0

if __name__ == "__main__":
    sys.exit(main())