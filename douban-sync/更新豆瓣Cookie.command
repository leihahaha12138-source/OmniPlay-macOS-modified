#!/bin/bash
# 更新豆瓣 Cookie —— 双击运行
# ---------------------------------------------------------------
# 用途：把剪贴板里的豆瓣 cookie 写入同步器，然后立刻重试「需登录可见」的影片。
# 何时用：同步日志提示 cookie 过期，或同步器目录里出现「！需要更新豆瓣cookie.txt」。
# ---------------------------------------------------------------
set -u

BASE="$HOME/.omniplay-douban-sync"
COOKIE="$BASE/douban-cookie.txt"
NOTICE="$BASE/！需要更新豆瓣cookie.txt"
LABEL="com.omniplay.douban-sync"
PATTERN="douban_sync.py --daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

pause() { printf '\n按任意键关闭…'; read -n 1 -s -r </dev/tty 2>/dev/null || true; printf '\n'; }

echo "════════════════════════════════════════"
echo " 更新豆瓣 Cookie"
echo "════════════════════════════════════════"
echo

# ---------- 1) 读取剪贴板 ----------
RAW="$(pbpaste 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
RAW="$(printf '%s' "$RAW" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
# 容错：整行复制时可能带 "cookie:" 前缀
RAW="$(printf '%s' "$RAW" | sed -E 's/^[Cc]ookie[[:space:]]*:[[:space:]]*//')"

if [ -z "$RAW" ]; then
  echo "✘ 剪贴板是空的。"
  echo "  请先按 README「豆瓣登录态 cookie」一节把 cookie 复制好，再运行本程序。"
  pause; exit 1
fi

if ! printf '%s' "$RAW" | grep -q 'dbcl2'; then
  echo "✘ 剪贴板里没有 dbcl2 —— 看起来不是豆瓣 cookie。"
  echo "  当前剪贴板开头：「$(printf '%s' "$RAW" | cut -c1-70)…」"
  pause; exit 1
fi

# ---------- 2) 写入（0600） ----------
umask 077
mkdir -p "$BASE"
printf '%s\n' "$RAW" > "$COOKIE"
chmod 600 "$COOKIE"
echo "✔ 已写入 $COOKIE"
echo "  （$(wc -c < "$COOKIE" | tr -d ' ') 字节，权限 600）"
echo

# ---------- 3) 重启守护进程（Python 不会热重载） ----------
OLD="$(pgrep -f "$PATTERN" 2>/dev/null || true)"
if [ -n "$OLD" ]; then
  echo "→ 重启守护进程（旧 PID $OLD）…"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || kill "$OLD" 2>/dev/null || true
  sleep 4
  if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    echo "✔ 守护进程已重启"
  else
    echo "⚠ 未自动拉起，重新注册 LaunchAgent…"
    launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
      || launchctl load "$PLIST" >/dev/null 2>&1 || true
    sleep 3
    if pgrep -f "$PATTERN" >/dev/null 2>&1; then
      echo "✔ 守护进程已启动"
    else
      echo "⚠ 仍未启动 —— 请双击「安装觅影豆瓣同步.command」重装一次。"
    fi
  fi
else
  echo "→ 守护进程当前没在运行，跳过重启（下次觅影关闭时会自动同步）"
fi
echo

# ---------- 4) 立刻重试 ----------
echo "→ 立即重试所有待同步影片（忽略冷却期）…"
echo
/usr/bin/python3 "$BASE/douban_sync.py" --once --force
echo

# ---------- 5) 收尾 ----------
if [ -f "$NOTICE" ]; then
  echo "⚠ 仍有影片需要登录态，详见："
  echo "   $NOTICE"
else
  echo "✔ 所有影片都已取到豆瓣数据，提示文件已自动清除。"
fi
echo
echo "提示：重启一次觅影即可看到最新评分与海报。"
pause
