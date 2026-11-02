#!/bin/bash
# ============================================================
# 觅影豆瓣同步器 - 安装脚本
# 安装后：每次启动觅影，守护进程会自动触发一次豆瓣同步
# 卸载：运行 uninstall.sh
# ============================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HOME/.omniplay-douban-sync"
PLIST="$HOME/Library/LaunchAgents/com.omniplay.douban-sync.plist"
PY="/usr/bin/python3"

echo "=== 觅影豆瓣同步器 安装 ==="
echo "源目录:   $SRC_DIR"
echo "安装目录: $DEST_DIR"

# 1. 停止旧守护（若存在）
if launchctl list | grep -q "com.omniplay.douban-sync" 2>/dev/null; then
    echo ">> 停止旧守护进程"
    launchctl bootout "gui/$(id -u)/com.omniplay.douban-sync" 2>/dev/null || \
        launchctl remove com.omniplay.douban-sync 2>/dev/null || true
    sleep 1
fi

# 2. 拷贝文件
mkdir -p "$DEST_DIR"
cp "$SRC_DIR/douban_sync.py" "$DEST_DIR/"
if [ -f "$SRC_DIR/config.json" ]; then cp "$SRC_DIR/config.json" "$DEST_DIR/"; fi
echo ">> 文件已拷贝"

# 3. 写 LaunchAgent plist
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.omniplay.douban-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$DEST_DIR/douban_sync.py</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DEST_DIR/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$DEST_DIR/daemon.err.log</string>
</dict>
</plist>
EOF
echo ">> LaunchAgent 已写入: $PLIST"

# 4. 加载守护（GUI 会话内 launchctl bootstrap；非 GUI 环境会失败并提示）
if launchctl print "gui/$(id -u)/com.omniplay.douban-sync" >/dev/null 2>&1; then
    echo ">> 守护进程已在运行"
else
    OUT=$(launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1) && RC=0 || RC=$?
    if [ $RC -ne 0 ]; then
        # 非 GUI 会话(如远程/Agent)时用 asuser 再试
        OUT2=$(launchctl asuser "$(id -u)" launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1) && RC=0 || RC=$?
        if [ $RC -ne 0 ]; then
            echo "!! 无法注册守护进程（bootstrap 失败: $OUT2）"
            echo "   原因：当前终端不在 macOS 图形登录会话中。"
            echo "   解决办法：双击运行项目里的「安装觅影豆瓣同步.command」"
            echo "   或在「终端」App 里手动执行："
            echo "     launchctl bootstrap gui/$(id -u) $PLIST"
            echo
            echo "（程序文件已就位，不影响手动同步；仅“自动随觅影启动”需注册守护）"
        else
            echo ">> 守护进程已加载（asuser）"
        fi
    else
        echo ">> 守护进程已加载"
    fi
fi

sleep 1
echo
echo "=== 安装完成 ==="
echo "守护进程状态："
launchctl list | grep "omniplay.douban-sync" || echo "(未在列表中，见上方错误)"
echo
echo "日志: $DEST_DIR/sync.log"
echo
echo "立即手动跑一次同步（预览用 --dry-run，真实执行用 --once）："
echo "  $PY $DEST_DIR/douban_sync.py --dry-run"
echo "  $PY $DEST_DIR/douban_sync.py --once"
