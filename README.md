# nastest v1.0 - 联想凌拓 MCC NAS 性能测试工具

纯 Shell 实现的 NAS 多客户端并发压力测试工具, 用于 Lenovo NetApp MetroCluster 双活 NAS 存储性能验证.

专为银行等离线环境设计, 无需 Python 或任何高级运行时.

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/NetApptool/nastest/main/get-nastest.sh | sudo bash
```

自动完成: 下载 → 解压 → 安装 → 启动交互式配置向导.

## 离线安装

适用于无法联网的客户环境:

```bash
# 1. 在有网络的机器上下载
wget https://github.com/NetApptool/nastest/releases/download/v1.0/nastest-v1.0.tar.gz

# 2. 传输到目标机器后解压安装
tar xzf nastest-v1.0.tar.gz && cd nastest
sudo ./install.sh

# 3. 启动配置向导
cd /opt/nastest && ./nas_bench.sh setup
```

## 功能特性

- **交互式配置向导** - 问答式引导, 不需要手动编辑配置文件
- **多客户端并发** - 同时在多台 Worker VM 上执行 fio 压测
- **双站点对比** - Site A / Site B 性能均衡性分析, 专为 MetroCluster 设计
- **实时进度条** - 压测过程实时显示进度百分比和剩余时间
- **HTML 可视化报告** - 自包含单文件, 浏览器直接打开, 含深浅色切换
- **面向非技术人员的结论** - 自动生成通俗易懂的测试结论和术语解释
- **零依赖部署** - 内置静态编译的 fio/iperf3, 无需目标机器安装任何软件
- **离线友好** - 专为银行麒麟 Linux 等离线环境设计

## 配置向导

首次使用推荐通过交互式向导完成配置:

```bash
./nas_bench.sh setup
```

向导流程:
1. 填写 NFS 服务器地址和路径 (自动检测连通性)
2. 逐台填写 Worker VM 信息 (每台即时验证 SSH 连接)
3. 选择测试模式和时长
4. 确认配置后自动开始测试

## 手动配置

```bash
vi /opt/nastest/hosts.txt    # 填写配置
./nas_bench.sh start         # 开始测试
```

配置文件格式:

```
NFS_SERVER=10.0.0.100
NFS_PATH=/vol_test
NFS_VERSION=4

# Worker列表: IP  密码  站点(A/B)
192.168.10.101  P@ssw0rd  A
192.168.10.102  P@ssw0rd  A
192.168.10.103  P@ssw0rd  B
192.168.10.104  P@ssw0rd  B
```

## 测试模式

| 模式 | 参数 | 块大小 | 场景 |
|------|------|--------|------|
| 随机读写 | `--mode randrw` | 4K | 数据库 / OLTP 交易系统 (默认) |
| 顺序读写 | `--mode seq` | 1M | 备份归档 / 大文件传输 |
| 混合读写 | `--mode mixed` | 8K | 通用文件服务 |

## 命令参考

```bash
./nas_bench.sh setup                          # 交互式配置向导 (推荐)
./nas_bench.sh start                          # 使用已有配置开始测试
./nas_bench.sh start --mode seq               # 顺序读写模式
./nas_bench.sh start --mode mixed             # 混合读写模式
./nas_bench.sh start --duration 600           # 自定义时长(秒)
./nas_bench.sh start --port 2222              # 指定SSH端口
./nas_bench.sh check                          # 仅检测连通性
./nas_bench.sh clean                          # 清理远程测试数据
```

## HTML 报告

测试完成后自动生成可视化报告, 包含:

- 汇总指标卡片 (IOPS / 吞吐 / 延迟 / P95 / P99)
- 双站点对比分析和偏差评估
- Worker 性能明细表
- 系统资源利用率
- 面向非技术人员的测试结论
- 术语通俗解释

报告为自包含 HTML 单文件, 支持深色/浅色切换, 浏览器直接打开.

## 系统要求

| 项目 | 要求 |
|------|------|
| 架构 | x86_64 |
| 操作系统 | Linux (麒麟 / CentOS / RHEL / Ubuntu) |
| 权限 | root |
| 依赖 | sshpass (密码认证), nfs-utils (NFS挂载), libaio (fio引擎) |
| 网络 | 主控节点可 SSH 到所有 Worker VM |

## 文件结构

```
nastest/
├── get-nastest.sh   # 一键安装脚本 (在线)
├── install.sh       # 安装脚本 (离线)
├── nas_bench.sh     # 主控脚本
├── report.sh        # HTML 报告生成器
├── hosts.txt        # 配置文件模板
├── bin/
│   ├── fio          # fio 3.37
│   └── iperf3       # iperf3 3.20 (静态链接)
├── templates/       # fio 测试模板
│   ├── randrw.ini   # 随机读写 4K
│   ├── seqrw.ini    # 顺序读写 1M
│   └── mixed.ini    # 混合读写 8K
└── deps/            # 离线 RPM 包 (可选)
```

## License

Internal use - Lenovo NetApp Technology
