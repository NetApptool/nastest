#!/bin/bash
# ============================================
# nastest v1.0 一键安装脚本
# 联想凌拓 MCC NAS 性能测试工具
# ============================================
set -e

VERSION="v1.0"
REPO="NetApptool/nastest"
INSTALL_DIR="/opt/nastest"
TMP_DIR=$(mktemp -d)

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}联想凌拓 NAS 性能测试工具 - 在线安装${NC}"
echo ""

# 检查root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 用户运行${NC}"
    echo "  用法: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/get-nastest.sh | sudo bash"
    exit 1
fi

# 检查架构
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo -e "${RED}[错误] 仅支持 x86_64 架构, 检测到: $ARCH${NC}"
    exit 1
fi

# 检查必要命令
MISSING=""
for cmd in tar gzip; do
    if ! which $cmd >/dev/null 2>&1; then
        MISSING="$MISSING $cmd"
    fi
done
if [ -n "$MISSING" ]; then
    echo -e "${RED}[错误] 缺少必要命令:${MISSING}${NC}"
    echo "  请先安装: yum install -y tar gzip  或  dnf install -y tar gzip"
    rm -rf "$TMP_DIR"
    exit 1
fi

# 下载
echo -e "  下载 nastest ${VERSION}..."
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/nastest-${VERSION}.tar.gz"

if which curl >/dev/null 2>&1; then
    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/nastest.tar.gz"
elif which wget >/dev/null 2>&1; then
    wget -q "$DOWNLOAD_URL" -O "$TMP_DIR/nastest.tar.gz"
else
    echo -e "${RED}[错误] 未找到 curl 或 wget${NC}"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo -e "  ${GREEN}下载完成${NC}"

# 解压并安装
echo -e "  解压并安装..."
cd "$TMP_DIR"
tar xzf nastest.tar.gz
cd nastest
bash ./install.sh

# 清理
rm -rf "$TMP_DIR"

# 启动配置向导
echo ""
echo -e "  ${GREEN}安装完成! 正在启动配置向导...${NC}"
echo ""
cd "$INSTALL_DIR"
exec ./nas_bench.sh setup
