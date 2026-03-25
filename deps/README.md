# 离线依赖目录

此目录用于存放离线安装所需的 RPM 包。

## 可能需要的 RPM 包

- `nfs-utils` - NFS 客户端工具
- `libaio` - 异步 I/O 库 (fio 依赖)
- `sshpass` - SSH 密码自动输入工具

## 获取方式

在有网络的同版本系统上执行:

```bash
# 下载 nfs-utils 及其依赖
yum install --downloadonly --downloaddir=./deps nfs-utils

# 下载 sshpass
yum install --downloadonly --downloaddir=./deps sshpass

# 下载 libaio
yum install --downloadonly --downloaddir=./deps libaio
```

将下载的 RPM 文件放入此目录即可。
