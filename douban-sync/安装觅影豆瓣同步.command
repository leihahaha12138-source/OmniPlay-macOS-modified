#!/bin/bash
# ============================================================
# 安装「觅影豆瓣同步」守护进程
# 双击本文件即可安装（会在终端窗口弹出）。
# 安装后：每次启动觅影，自动同步一次豆瓣评分 + 海报。
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=============================================="
echo "  觅影(OmniPlay) 豆瓣评分+海报 自动同步 安装器"
echo "=============================================="
echo
echo "即将执行以下操作："
echo "  1. 拷贝程序到 ~/.omniplay-douban-sync/"
echo "  2. 注册守护进程 com.omniplay.douban-sync"
echo "     (每次启动觅影自动触发一次同步)"
echo

cd "$DIR"
./install.sh

echo
echo "----------------------------------------------"
echo "安装完成！建议立即跑一次首轮同步："
echo "  在终端执行:"
echo "    /usr/bin/python3 ~/.omniplay-douban-sync/douban_sync.py --once"
echo
echo "日志文件: ~/.omniplay-douban-sync/sync.log"
echo "卸载方式: ~/.omniplay-douban-sync/uninstall.sh"
echo "----------------------------------------------"
echo
read -n 1 -s -r -p "按任意键关闭窗口..."
echo
