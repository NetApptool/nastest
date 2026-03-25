#!/bin/bash
# ============================================
# 联想凌拓 NAS 性能测试工具 - 安装脚本
# ============================================
set -e

INSTALL_DIR="/opt/nastest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "============================================"
echo "  联想凌拓 NAS 性能测试工具 v1.0 安装"
echo "============================================"
echo ""

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 用户运行此脚本"
    echo "  用法: sudo ./install.sh"
    exit 1
fi

# 检查操作系统
echo "[1/5] 检测操作系统..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "  系统: $PRETTY_NAME"
    echo "  内核: $(uname -r)"
    echo "  架构: $(uname -m)"
else
    echo "  [警告] 无法识别操作系统, 继续安装..."
fi

# 检查架构
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo "  [错误] 当前仅支持 x86_64 架构, 检测到: $ARCH"
    exit 1
fi

# 检查SSH
echo ""
echo "[2/5] 检测SSH服务..."
if systemctl is-active sshd >/dev/null 2>&1; then
    echo "  SSH 服务: 正常运行"
elif systemctl is-active ssh >/dev/null 2>&1; then
    echo "  SSH 服务: 正常运行"
else
    echo "  [警告] SSH服务未运行, 尝试启动..."
    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || {
        echo "  [错误] 无法启动SSH服务, 请手动启动后重试"
        exit 1
    }
    echo "  SSH 服务: 已启动"
fi

# 检查NFS客户端
echo ""
echo "[3/5] 检测NFS客户端..."
if which mount.nfs >/dev/null 2>&1; then
    echo "  NFS 客户端: 已安装"
else
    echo "  [警告] 未检测到NFS客户端"
    if ls "$SCRIPT_DIR"/deps/nfs-utils*.rpm >/dev/null 2>&1; then
        echo "  尝试离线安装 nfs-utils..."
        rpm -ivh "$SCRIPT_DIR"/deps/nfs-utils*.rpm --nodeps 2>/dev/null && {
            echo "  NFS 客户端: 离线安装成功"
        } || {
            echo "  [错误] 离线安装失败"
            echo "  请手动安装: yum install -y nfs-utils"
            exit 1
        }
    else
        echo "  [错误] 未找到离线RPM包且系统中无NFS客户端"
        echo "  请手动安装: yum install -y nfs-utils"
        echo "  或将 nfs-utils RPM 放入 deps/ 目录后重新运行"
        exit 1
    fi
fi

# 部署文件
echo ""
echo "[4/5] 部署测试工具..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/results"

cp "$SCRIPT_DIR/bin/fio" "$INSTALL_DIR/bin/" 2>/dev/null && chmod +x "$INSTALL_DIR/bin/fio" && echo "  fio: 已部署" || echo "  [警告] fio 二进制未找到"
cp "$SCRIPT_DIR/bin/iperf3" "$INSTALL_DIR/bin/" 2>/dev/null && chmod +x "$INSTALL_DIR/bin/iperf3" && echo "  iperf3: 已部署" || echo "  [警告] iperf3 二进制未找到"
cp "$SCRIPT_DIR/nas_bench.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/nas_bench.sh" && echo "  nas_bench.sh: 已部署"
cp "$SCRIPT_DIR/report.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/report.sh" && echo "  report.sh: 已部署"
cp "$SCRIPT_DIR/hosts.txt" "$INSTALL_DIR/" && echo "  hosts.txt: 已部署"
cp "$SCRIPT_DIR"/templates/*.ini "$INSTALL_DIR/templates/" 2>/dev/null && echo "  fio模板: 已部署"

# 创建软链接
ln -sf "$INSTALL_DIR/nas_bench.sh" /usr/local/bin/nas_bench 2>/dev/null

# 验证fio
echo ""
echo "[5/5] 验证工具..."
if [ -f "$INSTALL_DIR/bin/fio" ]; then
    FIO_VER=$("$INSTALL_DIR/bin/fio" --version 2>/dev/null || echo "未知")
    echo "  fio 版本: $FIO_VER"
else
    echo "  [警告] fio未部署, 压测功能将不可用"
fi
if [ -f "$INSTALL_DIR/bin/iperf3" ]; then
    IPERF_VER=$("$INSTALL_DIR/bin/iperf3" --version 2>/dev/null | head -1 || echo "未知")
    echo "  iperf3 版本: $IPERF_VER"
fi

echo ""
echo "============================================"
echo "  安装完成!"
echo "============================================"
echo ""
echo "  安装目录: $INSTALL_DIR"
echo ""
echo "  下一步:"
echo "  1. 运行配置向导:  cd $INSTALL_DIR && ./nas_bench.sh setup"
echo "     按提示填写Worker信息, 完成后自动开始测试"
echo ""
echo "  可用命令:"
echo "    ./nas_bench.sh setup              # 交互式配置向导 (推荐)"
echo "    ./nas_bench.sh start              # 默认: 随机读写, 300秒"
echo "    ./nas_bench.sh start --mode seq   # 顺序读写模式"
echo "    ./nas_bench.sh start --mode mixed # 混合读写模式"
echo "    ./nas_bench.sh start --duration 600  # 自定义时长(秒)"
echo "    ./nas_bench.sh check              # 仅检测连通性"
echo "    ./nas_bench.sh clean              # 清理测试数据"
echo ""
