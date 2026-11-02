#!/bin/bash
# 觅影豆瓣同步器 - 卸载脚本
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.omniplay.douban-sync.plist"
DEST_DIR="$HOME/.omniplay-douban-sync"

echo "=== 卸载觅影豆瓣同步器 ==="

if launchctl list | grep -q "com.omniplay.douban-sync" 2>/dev/null; then
    echo ">> 停止守护进程"
    launchctl bootout "gui/$(id -u)/com.omniplay.douban-sync" 2>/dev/null || \
        launchctl remove com.omniplay.douban-sync 2>/dev/null || true
    sleep 1
fi

if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    echo ">> 已删除 $PLIST"
fi

if [ -d "$DEST_DIR" ]; then
    # 保留 review.tsv / backups / state.json 以防你想恢复，仅删程序本体
    rm -f "$DEST_DIR/douban_sync.py" "$DEST_DIR/config.json"
    echo ">> 已删除程序文件（保留 $DEST_DIR/review.tsv 与 backups/）"
    echo "   如需完全清除数据：rm -rf $DEST_DIR"
fi

echo "=== 卸载完成 ==="
