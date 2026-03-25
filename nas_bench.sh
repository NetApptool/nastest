#!/bin/bash
# ============================================
# 联想凌拓 NAS 性能测试工具 v1.0
# 主控脚本
# ============================================
set -o pipefail

VERSION="1.0"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FIO_BIN="$BASE_DIR/bin/fio"
RESULTS_DIR="$BASE_DIR/results"
CONFIG_FILE="$BASE_DIR/hosts.txt"
TEMPLATES_DIR="$BASE_DIR/templates"
REMOTE_DIR="/tmp/nastest"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 默认参数
MODE="randrw"
DURATION=300
SSH_PORT=22

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ========== 辅助函数 ==========
log_step() { echo -e "\n${BLUE}[$1]${NC} $2"; }
log_ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}[警告]${NC} $1"; }
log_fail() { echo -e "  ${RED}[失败]${NC} $1"; }
log_info() { echo -e "  ${CYAN}[信息]${NC} $1"; }

# ========== 解析配置文件 ==========
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[错误] 配置文件不存在: $CONFIG_FILE${NC}"
        echo "  请先编辑 hosts.txt 填写Worker信息"
        exit 1
    fi

    NFS_SERVER=""
    NFS_PATH=""
    NFS_VERSION="4"
    WORKERS=()

    while IFS= read -r line; do
        # 跳过空行和注释
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -z "$line" ] && continue

        # 解析NFS配置
        if echo "$line" | grep -q "^NFS_SERVER="; then
            NFS_SERVER=$(echo "$line" | cut -d= -f2 | xargs)
            continue
        fi
        if echo "$line" | grep -q "^NFS_PATH="; then
            NFS_PATH=$(echo "$line" | cut -d= -f2 | xargs)
            continue
        fi
        if echo "$line" | grep -q "^NFS_VERSION="; then
            NFS_VERSION=$(echo "$line" | cut -d= -f2 | xargs)
            continue
        fi

        # 解析Worker行: IP  密码  站点(可选)
        WORKER_IP=$(echo "$line" | awk '{print $1}')
        WORKER_PASS=$(echo "$line" | awk '{print $2}')
        WORKER_SITE=$(echo "$line" | awk '{print $3}')
        [ -z "$WORKER_SITE" ] && WORKER_SITE="A"

        if [ -n "$WORKER_IP" ] && [ -n "$WORKER_PASS" ]; then
            WORKERS+=("$WORKER_IP $WORKER_PASS $WORKER_SITE")
        fi
    done < "$CONFIG_FILE"

    # 验证
    if [ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]; then
        echo -e "${RED}[错误] hosts.txt 中未配置 NFS_SERVER 或 NFS_PATH${NC}"
        exit 1
    fi
    if [ ${#WORKERS[@]} -eq 0 ]; then
        echo -e "${RED}[错误] hosts.txt 中未配置任何Worker VM${NC}"
        exit 1
    fi
}

# ========== SSH执行远程命令 ==========
ssh_exec() {
    local ip=$1 pass=$2 cmd=$3
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -p "$pass" ssh $SSH_OPTS -p $SSH_PORT root@"$ip" "$cmd" 2>/dev/null
    else
        ssh $SSH_OPTS -p $SSH_PORT root@"$ip" "$cmd" 2>/dev/null
    fi
}

# ========== SCP传输文件 ==========
scp_to() {
    local ip=$1 pass=$2 src=$3 dst=$4
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -p "$pass" scp $SSH_OPTS -P $SSH_PORT "$src" root@"$ip":"$dst" 2>/dev/null
    else
        scp $SSH_OPTS -P $SSH_PORT "$src" root@"$ip":"$dst" 2>/dev/null
    fi
}

scp_from() {
    local ip=$1 pass=$2 src=$3 dst=$4
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -p "$pass" scp $SSH_OPTS -P $SSH_PORT root@"$ip":"$src" "$dst" 2>/dev/null
    else
        scp $SSH_OPTS -P $SSH_PORT root@"$ip":"$src" "$dst" 2>/dev/null
    fi
}

# ========== 检测sshpass ==========
check_sshpass() {
    if which sshpass >/dev/null 2>&1; then
        USE_SSHPASS=1
    else
        echo -e "${YELLOW}[提示] 未检测到 sshpass, 将使用SSH密钥认证${NC}"
        echo "  如需密码自动登录, 请安装: yum install -y sshpass"
        echo ""
        USE_SSHPASS=0
    fi
}

# ========== 阶段1: 检测Worker连通性 ==========
check_workers() {
    log_step "1/${TOTAL_STEPS}" "检测Worker连通性..."

    LIVE_WORKERS=()
    for entry in "${WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')
        local site=$(echo "$entry" | awk '{print $3}')

        local sys_info
        sys_info=$(ssh_exec "$ip" "$pass" "
            source /etc/os-release 2>/dev/null
            CORES=\$(nproc)
            MEM=\$(free -g | awk '/Mem:/{print \$2}')
            echo \"\$PRETTY_NAME|\${CORES}核|\${MEM}GB\"
        " 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$sys_info" ]; then
            local os_name=$(echo "$sys_info" | cut -d'|' -f1)
            local cores=$(echo "$sys_info" | cut -d'|' -f2)
            local mem=$(echo "$sys_info" | cut -d'|' -f3)
            log_ok "$ip - 连接正常 ($os_name, $cores/$mem) [Site $site]"
            LIVE_WORKERS+=("$entry")
        else
            log_fail "$ip - 连接失败, 已跳过"
        fi
    done

    if [ ${#LIVE_WORKERS[@]} -eq 0 ]; then
        echo -e "\n${RED}[错误] 没有可用的Worker, 请检查hosts.txt中的IP和密码${NC}"
        exit 1
    fi

    echo -e "\n  可用Worker: ${GREEN}${#LIVE_WORKERS[@]}${NC} / ${#WORKERS[@]} 台"
}

# ========== 阶段2: 分发测试工具 ==========
deploy_workers() {
    log_step "2/${TOTAL_STEPS}" "分发测试工具到Worker..."

    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')

        ssh_exec "$ip" "$pass" "mkdir -p $REMOTE_DIR"
        scp_to "$ip" "$pass" "$FIO_BIN" "$REMOTE_DIR/fio"
        ssh_exec "$ip" "$pass" "chmod +x $REMOTE_DIR/fio"

        local remote_ver
        remote_ver=$(ssh_exec "$ip" "$pass" "$REMOTE_DIR/fio --version" 2>/dev/null)
        if [ -n "$remote_ver" ]; then
            log_ok "$ip - fio 部署成功 ($remote_ver)"
        else
            log_fail "$ip - fio 部署失败"
        fi
    done
}

# ========== 阶段3: 挂载NFS ==========
# 挂载参数遵循 NetApp TR-4067 NFS Best Practice:
#   hard        - 必须, 防止 soft mount 导致数据损坏
#   proto=tcp   - 显式指定 TCP (禁止 UDP)
#   rsize/wsize=65536 - NetApp 官方推荐最佳平衡值
#   noatime     - 减少不必要的元数据写 I/O
#   nconnect=8  - 单挂载点多 TCP 连接并发, 内核 5.3+ 支持, 对吞吐提升显著
mount_nfs() {
    log_step "3/${TOTAL_STEPS}" "挂载NFS存储 (${NFS_SERVER}:${NFS_PATH})..."

    local nfs_mount_point="/mnt/nastest_nfs"
    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')

        # 检测远程内核版本, 5.3+ 启用 nconnect=8
        local nconnect_opt=""
        local remote_kver
        remote_kver=$(ssh_exec "$ip" "$pass" "uname -r" 2>/dev/null)
        if [ -n "$remote_kver" ]; then
            local kver_major=$(echo "$remote_kver" | cut -d. -f1)
            local kver_minor=$(echo "$remote_kver" | cut -d. -f2)
            if [ "$kver_major" -gt 5 ] 2>/dev/null || { [ "$kver_major" -eq 5 ] && [ "$kver_minor" -ge 3 ]; } 2>/dev/null; then
                nconnect_opt=",nconnect=8"
                log_info "$ip - 内核 $remote_kver 支持 nconnect, 启用多连接并发"
            else
                log_info "$ip - 内核 $remote_kver 不支持 nconnect (需5.3+), 跳过"
            fi
        fi

        local mount_opts="vers=${NFS_VERSION},rw,hard,proto=tcp,rsize=65536,wsize=65536,noatime${nconnect_opt}"

        ssh_exec "$ip" "$pass" "
            umount $nfs_mount_point 2>/dev/null
            mkdir -p $nfs_mount_point
            mount -t nfs -o ${mount_opts} \
                ${NFS_SERVER}:${NFS_PATH} $nfs_mount_point
        "

        if [ $? -eq 0 ]; then
            local mount_check
            mount_check=$(ssh_exec "$ip" "$pass" "df -h $nfs_mount_point 2>/dev/null | tail -1")
            if [ -n "$mount_check" ]; then
                log_ok "$ip -> NFSv${NFS_VERSION} 挂载成功 (opts: ${mount_opts})"
            else
                log_fail "$ip -> 挂载验证失败"
            fi
        else
            log_fail "$ip -> NFS挂载失败, 请检查NFS服务器地址和网络"
        fi

        ssh_exec "$ip" "$pass" "mkdir -p $nfs_mount_point/fio_test_\$(hostname -s)"
    done
}

# ========== 阶段4: 运行压测 ==========
run_benchmark() {
    local mode_name=""
    local template_file=""
    case "$MODE" in
        randrw)   mode_name="随机读写 4K";  template_file="$TEMPLATES_DIR/randrw.ini" ;;
        seq)      mode_name="顺序读写 1M";  template_file="$TEMPLATES_DIR/seqrw.ini" ;;
        mixed)    mode_name="混合读写 8K";   template_file="$TEMPLATES_DIR/mixed.ini" ;;
    esac

    log_step "4/${TOTAL_STEPS}" "开始性能测试 (预计 ${DURATION} 秒)..."
    echo ""
    echo -e "  模式: ${BOLD}${mode_name}${NC} | 并发Worker: ${BOLD}${#LIVE_WORKERS[@]}台${NC} | 持续时间: ${BOLD}${DURATION}秒${NC}"
    echo ""

    # 读取模板并替换变量
    local fio_config
    fio_config=$(cat "$template_file" | sed "s/\${DURATION}/$DURATION/g" | sed 's|\${FIO_DIR}|/mnt/nastest_nfs/fio_test_\$(hostname -s)|g')

    mkdir -p "$RESULTS_DIR"
    local pids=()

    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')
        local site=$(echo "$entry" | awk '{print $3}')

        # 传输fio配置 (在远程替换hostname)
        echo "$fio_config" > "/tmp/fio_${ip}.ini"
        scp_to "$ip" "$pass" "/tmp/fio_${ip}.ini" "$REMOTE_DIR/bench.ini"

        # 远程替换hostname并启动fio
        ssh_exec "$ip" "$pass" "
            cd $REMOTE_DIR
            sed -i \"s|\\\$(hostname -s)|\$(hostname -s)|g\" bench.ini
            ./fio bench.ini --output=$REMOTE_DIR/result.json --output-format=json
        " &
        pids+=($!)

        log_info "$ip [Site $site] - fio 已启动"
    done

    # 等待并显示进度
    echo ""
    local start_time=$(date +%s)
    local total=$DURATION

    while true; do
        local all_done=1
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                all_done=0
                break
            fi
        done

        if [ "$all_done" -eq 1 ]; then
            break
        fi

        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local remain=$((total - elapsed))
        [ $remain -lt 0 ] && remain=0
        local pct=$((elapsed * 100 / total))
        [ $pct -gt 100 ] && pct=100

        local bar_len=40
        local filled=$((pct * bar_len / 100))
        local empty=$((bar_len - filled))
        local bar=$(printf "%${filled}s" | tr ' ' '=')
        local space=$(printf "%${empty}s" | tr ' ' '.')

        printf "\r  [${GREEN}${bar}${NC}${space}] ${BOLD}%3d%%${NC}  已运行 %dm%02ds / 剩余 %dm%02ds " \
            "$pct" $((elapsed/60)) $((elapsed%60)) $((remain/60)) $((remain%60))

        sleep 2
    done

    echo ""
    echo ""
    echo -e "  ${GREEN}压测完成!${NC}"
}

# ========== fio JSON 解析函数 ==========
# 用awk解析fio JSON, 提取关键指标
# 用法: parse_fio_json <json_file>
# 输出: 设置环境变量 READ_IOPS WRITE_IOPS READ_BW WRITE_BW READ_LAT_NS WRITE_LAT_NS READ_P95_NS READ_P99_NS WRITE_P95_NS WRITE_P99_NS
parse_fio_json() {
    local json_file="$1"

    # 使用awk精确解析fio JSON结构
    # fio JSON: jobs[0].read/write.{iops, bw, clat_ns.mean, clat_ns.percentile.95.000000/99.000000}
    eval $(awk '
    BEGIN {
        section = ""
        in_clat = 0
        in_percentile = 0
        got_read_iops = 0
        got_write_iops = 0
        got_read_bw = 0
        got_write_bw = 0
        got_read_lat = 0
        got_write_lat = 0
        got_read_p95 = 0
        got_write_p95 = 0
        got_read_p99 = 0
        got_write_p99 = 0
    }

    # 检测进入 read/write 段
    /"read"[[:space:]]*:/ && !/"rw"/ && !/"read_/ { section = "read"; in_clat = 0; in_percentile = 0 }
    /"write"[[:space:]]*:/ && !/"write_/ { section = "write"; in_clat = 0; in_percentile = 0 }

    # 提取 iops (第一个匹配的iops字段, 不含iops_min等)
    section == "read" && /"iops"[[:space:]]*:/ && !/"iops_/ && got_read_iops == 0 {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9.]/, "", val)
        printf "READ_IOPS=%s\n", val
        got_read_iops = 1
    }
    section == "write" && /"iops"[[:space:]]*:/ && !/"iops_/ && got_write_iops == 0 {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9.]/, "", val)
        printf "WRITE_IOPS=%s\n", val
        got_write_iops = 1
    }

    # 提取 bw (KB/s)
    section == "read" && /"bw"[[:space:]]*:/ && !/"bw_/ && got_read_bw == 0 {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9.]/, "", val)
        printf "READ_BW=%s\n", val
        got_read_bw = 1
    }
    section == "write" && /"bw"[[:space:]]*:/ && !/"bw_/ && got_write_bw == 0 {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9.]/, "", val)
        printf "WRITE_BW=%s\n", val
        got_write_bw = 1
    }

    # 检测进入 clat_ns 段
    section != "" && /"clat_ns"/ { in_clat = 1; in_percentile = 0 }

    # 提取 clat_ns.mean
    in_clat == 1 && /"mean"/ {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9.]/, "", val)
        if (section == "read" && got_read_lat == 0) {
            printf "READ_LAT_NS=%s\n", val
            got_read_lat = 1
        }
        if (section == "write" && got_write_lat == 0) {
            printf "WRITE_LAT_NS=%s\n", val
            got_write_lat = 1
        }
    }

    # 检测进入 percentile 段
    in_clat == 1 && /"percentile"/ { in_percentile = 1 }

    # 提取 P95
    in_percentile == 1 && /"95.000000"/ {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9]/, "", val)
        if (section == "read" && got_read_p95 == 0) {
            printf "READ_P95_NS=%s\n", val
            got_read_p95 = 1
        }
        if (section == "write" && got_write_p95 == 0) {
            printf "WRITE_P95_NS=%s\n", val
            got_write_p95 = 1
        }
    }

    # 提取 P99
    in_percentile == 1 && /"99.000000"/ {
        val = $0
        gsub(/.*:/, "", val)
        gsub(/[^0-9]/, "", val)
        if (section == "read" && got_read_p99 == 0) {
            printf "READ_P99_NS=%s\n", val
            got_read_p99 = 1
        }
        if (section == "write" && got_write_p99 == 0) {
            printf "WRITE_P99_NS=%s\n", val
            got_write_p99 = 1
        }
    }

    # 退出 percentile 段 (遇到 } )
    in_percentile == 1 && /}/ && !/percentile/ {
        in_percentile = 0
        in_clat = 0
    }
    ' "$json_file" 2>/dev/null)
}

# ========== 阶段5: 收集结果 ==========
collect_results() {
    log_step "5/${TOTAL_STEPS}" "收集测试结果..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local run_dir="$RESULTS_DIR/run_${timestamp}"
    mkdir -p "$run_dir"

    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')
        local site=$(echo "$entry" | awk '{print $3}')

        # 拉回fio结果JSON
        scp_from "$ip" "$pass" "$REMOTE_DIR/result.json" "$run_dir/${ip}_fio.json"

        # 收集系统信息
        ssh_exec "$ip" "$pass" "
            echo \"IP=$ip\"
            echo \"SITE=$site\"
            echo \"HOSTNAME=\$(hostname)\"
            echo \"OS=\$(source /etc/os-release 2>/dev/null && echo \$PRETTY_NAME)\"
            echo \"KERNEL=\$(uname -r)\"
            echo \"CPU_CORES=\$(nproc)\"
            echo \"MEM_TOTAL_GB=\$(free -g | awk '/Mem:/{print \$2}')\"

            if which mpstat >/dev/null 2>&1; then
                CPU_IDLE=\$(mpstat 1 1 | tail -1 | awk '{print \$NF}')
                echo \"CPU_IDLE=\$CPU_IDLE\"
            else
                read cpu user nice system idle rest < /proc/stat
                total=\$((user+nice+system+idle))
                echo \"CPU_IDLE=\$((idle*100/total))\"
            fi

            IFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
            if [ -n \"\$IFACE\" ]; then
                RX1=\$(cat /proc/net/dev | grep \"\$IFACE\" | awk '{print \$2}')
                TX1=\$(cat /proc/net/dev | grep \"\$IFACE\" | awk '{print \$10}')
                sleep 1
                RX2=\$(cat /proc/net/dev | grep \"\$IFACE\" | awk '{print \$2}')
                TX2=\$(cat /proc/net/dev | grep \"\$IFACE\" | awk '{print \$10}')
                echo \"NET_RX_MBPS=\$(( (RX2-RX1) / 1048576 ))\"
                echo \"NET_TX_MBPS=\$(( (TX2-TX1) / 1048576 ))\"
                echo \"NET_IFACE=\$IFACE\"
            fi
        " > "$run_dir/${ip}_sysinfo.txt"

        if [ -f "$run_dir/${ip}_fio.json" ]; then
            log_ok "$ip [Site $site] - 结果已收集"
        else
            log_fail "$ip - 结果收集失败"
        fi
    done

    # 保存测试元数据
    local mode_name=""
    case "$MODE" in
        randrw)   mode_name="随机读写 4K" ;;
        seq)      mode_name="顺序读写 1M" ;;
        mixed)    mode_name="混合读写 8K" ;;
    esac

    cat > "$run_dir/metadata.txt" <<METAEOF
TIMESTAMP=$timestamp
MODE=$MODE
MODE_NAME=$mode_name
DURATION=$DURATION
NFS_SERVER=$NFS_SERVER
NFS_PATH=$NFS_PATH
NFS_VERSION=$NFS_VERSION
WORKER_COUNT=${#LIVE_WORKERS[@]}
FIO_VERSION=$("$FIO_BIN" --version 2>/dev/null)
METAEOF

    # 解析fio结果并保存
    > "$run_dir/parsed_results.txt"
    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local site=$(echo "$entry" | awk '{print $3}')
        local json_file="$run_dir/${ip}_fio.json"

        if [ -f "$json_file" ]; then
            # 清除之前的变量
            READ_IOPS="" WRITE_IOPS="" READ_BW="" WRITE_BW=""
            READ_LAT_NS="" WRITE_LAT_NS="" READ_P95_NS="" WRITE_P95_NS=""
            READ_P99_NS="" WRITE_P99_NS=""

            parse_fio_json "$json_file"

            # 计算合计
            local iops=$(awk "BEGIN{printf \"%.0f\", ${READ_IOPS:-0}+${WRITE_IOPS:-0}}")
            local bw_kb=$(awk "BEGIN{printf \"%.0f\", ${READ_BW:-0}+${WRITE_BW:-0}}")
            local lat_ns=$(awk "BEGIN{printf \"%.0f\", (${READ_LAT_NS:-0}+${WRITE_LAT_NS:-0})/2}")
            local p95_ns=$(awk "BEGIN{printf \"%.0f\", (${READ_P95_NS:-0}+${WRITE_P95_NS:-0})/2}")
            local p99_ns=$(awk "BEGIN{printf \"%.0f\", (${READ_P99_NS:-0}+${WRITE_P99_NS:-0})/2}")

            echo "IP=$ip SITE=$site IOPS=$iops BW_KB=$bw_kb LAT_NS=$lat_ns P95_NS=$p95_ns P99_NS=$p99_ns READ_IOPS=$(printf '%.0f' ${READ_IOPS:-0}) WRITE_IOPS=$(printf '%.0f' ${WRITE_IOPS:-0}) READ_BW=$(printf '%.0f' ${READ_BW:-0}) WRITE_BW=$(printf '%.0f' ${WRITE_BW:-0})" >> "$run_dir/parsed_results.txt"
        fi
    done

    # 生成报告
    echo ""
    log_info "生成测试报告..."
    bash "$BASE_DIR/report.sh" "$run_dir"

    LATEST_RUN_DIR="$run_dir"
}

# ========== 清理远程Worker ==========
clean_workers() {
    log_step "清理" "清理远程Worker测试数据..."
    for entry in "${LIVE_WORKERS[@]}"; do
        local ip=$(echo "$entry" | awk '{print $1}')
        local pass=$(echo "$entry" | awk '{print $2}')
        ssh_exec "$ip" "$pass" "
            umount /mnt/nastest_nfs 2>/dev/null
            rm -rf /tmp/nastest /mnt/nastest_nfs
        "
        log_ok "$ip - 已清理"
    done
}

# ========== 打印终端汇总表 ==========
print_summary() {
    local run_dir=$1
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  测试结果汇总${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    printf "  ${BOLD}%-18s %-8s %10s %10s %10s %10s %10s${NC}\n" \
        "Worker" "站点" "IOPS" "吞吐MB/s" "延迟ms" "P95ms" "P99ms"
    echo "  -----------------------------------------------------------------------"

    local total_iops=0
    local total_bw_kb=0

    if [ -f "$run_dir/parsed_results.txt" ]; then
        while IFS= read -r line; do
            local ip=$(echo "$line" | grep -oP '\bIP=\K[^ ]+' | head -1)
            local site=$(echo "$line" | grep -oP '\bSITE=\K[^ ]+' | head -1)
            local iops=$(echo "$line" | grep -oP '(?<= )IOPS=\K[^ ]+' | head -1)
            local bw_kb=$(echo "$line" | grep -oP '\bBW_KB=\K[^ ]+' | head -1)
            local lat_ns=$(echo "$line" | grep -oP '\bLAT_NS=\K[^ ]+' | head -1)
            local p95_ns=$(echo "$line" | grep -oP '\bP95_NS=\K[^ ]+' | head -1)
            local p99_ns=$(echo "$line" | grep -oP '\bP99_NS=\K[^ ]+' | head -1)

            local bw_mb=$(awk "BEGIN{printf \"%.1f\", ${bw_kb:-0}/1024}")
            local lat_ms=$(awk "BEGIN{printf \"%.2f\", ${lat_ns:-0}/1000000}")
            local p95_ms=$(awk "BEGIN{printf \"%.2f\", ${p95_ns:-0}/1000000}")
            local p99_ms=$(awk "BEGIN{printf \"%.2f\", ${p99_ns:-0}/1000000}")

            printf "  %-18s %-8s %10s %10s %10s %10s %10s\n" \
                "$ip" "Site $site" \
                "$iops" "$bw_mb" "$lat_ms" "$p95_ms" "$p99_ms"

            total_iops=$((total_iops + ${iops:-0}))
            total_bw_kb=$((total_bw_kb + ${bw_kb:-0}))
        done < "$run_dir/parsed_results.txt"
    fi

    echo "  -----------------------------------------------------------------------"
    local total_bw_mb=$(awk "BEGIN{printf \"%.1f\", $total_bw_kb/1024}")
    printf "  ${BOLD}%-18s %-8s %10s %10s${NC}\n" \
        "合计" "" "$total_iops" "$total_bw_mb"
    echo ""

    if [ -f "$run_dir/report.html" ]; then
        echo -e "  ${GREEN}HTML 报告: $run_dir/report.html${NC}"
        echo ""
    fi
}

# ========== 交互式配置向导 ==========
interactive_setup() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  联想凌拓 NAS 性能测试工具 v${VERSION} - 配置向导${NC}"
    echo -e "${BOLD}============================================${NC}"

    check_sshpass

    # 检查是否已有有效配置
    if [ -f "$CONFIG_FILE" ]; then
        local existing_server="" existing_path="" existing_count=0
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | xargs)
            [ -z "$line" ] && continue
            if echo "$line" | grep -q "^NFS_SERVER="; then
                existing_server=$(echo "$line" | cut -d= -f2 | xargs)
            elif echo "$line" | grep -q "^NFS_PATH="; then
                existing_path=$(echo "$line" | cut -d= -f2 | xargs)
            elif echo "$line" | grep -q "^NFS_"; then
                :
            elif [ -n "$(echo "$line" | awk '{print $1}')" ] && [ -n "$(echo "$line" | awk '{print $2}')" ]; then
                existing_count=$((existing_count + 1))
            fi
        done < "$CONFIG_FILE"

        if [ -n "$existing_server" ] && [ $existing_count -gt 0 ]; then
            echo ""
            echo -e "  检测到已有配置 (${BOLD}${existing_count}台Worker${NC}, NFS: ${BOLD}${existing_server}:${existing_path}${NC})"
            printf "  是否重新配置? [y/N]: "
            read -r reconf
            if [ "$reconf" != "y" ] && [ "$reconf" != "Y" ]; then
                echo ""
                echo -e "  ${GREEN}使用现有配置${NC}"
                # 询问是否直接开始测试
                echo ""
                printf "  是否立即开始测试? [Y/n]: "
                read -r run_now
                if [ "$run_now" != "n" ] && [ "$run_now" != "N" ]; then
                    _run_full_test
                fi
                return
            fi
        fi
    fi

    # ========== 步骤 1/4: NFS 存储配置 ==========
    local setup_nfs_server="" setup_nfs_path="" setup_nfs_ver=""

    echo ""
    echo -e "${BLUE}[步骤 1/4]${NC} NFS 存储配置"
    echo ""

    while true; do
        printf "  请输入NFS服务器IP地址: "
        read -r setup_nfs_server
        if [ -z "$setup_nfs_server" ]; then
            echo -e "  ${RED}NFS服务器IP不能为空${NC}"
            continue
        fi
        break
    done

    while true; do
        printf "  请输入NFS共享路径: "
        read -r setup_nfs_path
        if [ -z "$setup_nfs_path" ]; then
            echo -e "  ${RED}NFS共享路径不能为空${NC}"
            continue
        fi
        break
    done

    printf "  NFS版本 [3/4] (默认4): "
    read -r setup_nfs_ver
    [ -z "$setup_nfs_ver" ] && setup_nfs_ver="4"

    # NFS连通性预检
    echo ""
    printf "  正在检测NFS连通性..."
    if which showmount >/dev/null 2>&1; then
        if showmount -e "$setup_nfs_server" >/dev/null 2>&1; then
            echo -e " ${GREEN}✅${NC} NFS服务器 ${setup_nfs_server}:${setup_nfs_path} 可访问"
        else
            echo -e " ${YELLOW}⚠${NC}  showmount 检测失败 (可能NFS服务器限制了showmount, 不影响挂载)"
        fi
    else
        # 没有showmount, 尝试ping
        if ping -c 1 -W 2 "$setup_nfs_server" >/dev/null 2>&1; then
            echo -e " ${GREEN}✅${NC} NFS服务器 ${setup_nfs_server} 网络可达 (showmount未安装, 跳过NFS导出验证)"
        else
            echo -e " ${RED}❌${NC} NFS服务器 ${setup_nfs_server} 网络不可达"
            printf "  是否继续? [y/N]: "
            read -r cont
            if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
                echo "  已退出配置向导"
                return 1
            fi
        fi
    fi

    # ========== 步骤 2/4: Worker配置 ==========
    echo ""
    echo -e "${BLUE}[步骤 2/4]${NC} 测试客户端(Worker)配置"
    echo ""

    local setup_worker_count=""
    while true; do
        printf "  请输入Worker VM数量: "
        read -r setup_worker_count
        if ! echo "$setup_worker_count" | grep -qP '^\d+$' || [ "$setup_worker_count" -lt 1 ]; then
            echo -e "  ${RED}请输入有效的正整数${NC}"
            continue
        fi
        break
    done

    # SSH端口
    printf "  SSH端口 (默认22): "
    read -r setup_ssh_port
    [ -z "$setup_ssh_port" ] && setup_ssh_port="22"
    SSH_PORT="$setup_ssh_port"

    local setup_workers=()  # 存储: "IP PASSWORD SITE"
    local setup_sysinfos=() # 存储: "OS, CPU核/内存"

    local i=1
    while [ $i -le "$setup_worker_count" ]; do
        echo ""
        echo -e "  --- Worker $i ---"

        local w_ip="" w_pass="" w_site=""

        printf "  IP地址: "
        read -r w_ip
        if [ -z "$w_ip" ]; then
            echo -e "  ${RED}IP不能为空${NC}"
            continue
        fi

        printf "  root密码: "
        read -rs w_pass
        echo " ********"
        if [ -z "$w_pass" ]; then
            echo -e "  ${RED}密码不能为空${NC}"
            continue
        fi

        printf "  所属站点 [A/B] (默认A): "
        read -r w_site
        [ -z "$w_site" ] && w_site="A"
        w_site=$(echo "$w_site" | tr 'ab' 'AB')

        # 立即验证连通性
        printf "  正在检测连通性..."
        local sys_info
        if [ "$USE_SSHPASS" -eq 1 ]; then
            sys_info=$(sshpass -p "$w_pass" ssh $SSH_OPTS -p $SSH_PORT root@"$w_ip" "
                source /etc/os-release 2>/dev/null
                CORES=\$(nproc)
                MEM=\$(free -g | awk '/Mem:/{print \$2}')
                echo \"\$PRETTY_NAME|\${CORES}核|\${MEM}GB\"
            " 2>/dev/null)
        else
            sys_info=$(ssh $SSH_OPTS -p $SSH_PORT root@"$w_ip" "
                source /etc/os-release 2>/dev/null
                CORES=\$(nproc)
                MEM=\$(free -g | awk '/Mem:/{print \$2}')
                echo \"\$PRETTY_NAME|\${CORES}核|\${MEM}GB\"
            " 2>/dev/null)
        fi

        if [ $? -eq 0 ] && [ -n "$sys_info" ]; then
            local os_name=$(echo "$sys_info" | cut -d'|' -f1)
            local cores=$(echo "$sys_info" | cut -d'|' -f2)
            local mem=$(echo "$sys_info" | cut -d'|' -f3)
            echo -e " ${GREEN}✅${NC} 连接成功 ($os_name, $cores/$mem)"
            setup_workers+=("$w_ip $w_pass $w_site")
            setup_sysinfos+=("$os_name, $cores/$mem")
            i=$((i + 1))
        else
            echo -e " ${RED}❌${NC} $w_ip 连接失败"
            echo ""
            echo "    1) 重新输入此Worker信息"
            echo "    2) 跳过此Worker"
            echo "    3) 退出配置"
            printf "  请选择 [1/2/3]: "
            read -r fail_choice
            case "$fail_choice" in
                1) continue ;;
                2) i=$((i + 1)); continue ;;
                3) echo "  已退出配置向导"; return 1 ;;
                *) continue ;;
            esac
        fi
    done

    if [ ${#setup_workers[@]} -eq 0 ]; then
        echo -e "\n  ${RED}没有可用的Worker, 退出配置${NC}"
        return 1
    fi

    # ========== 步骤 3/4: 测试参数 ==========
    echo ""
    echo -e "${BLUE}[步骤 3/4]${NC} 测试参数"
    echo ""
    echo "  测试模式:"
    echo "    1) 随机读写 4K  - 模拟数据库/交易系统 (推荐)"
    echo "    2) 顺序读写 1M  - 模拟备份/大文件传输"
    echo "    3) 混合读写 8K  - 模拟通用文件服务"
    printf "  请选择 [1/2/3] (默认1): "
    read -r mode_choice
    [ -z "$mode_choice" ] && mode_choice="1"

    local setup_mode=""
    local setup_mode_name=""
    case "$mode_choice" in
        1) setup_mode="randrw"; setup_mode_name="随机读写 4K" ;;
        2) setup_mode="seq";    setup_mode_name="顺序读写 1M" ;;
        3) setup_mode="mixed";  setup_mode_name="混合读写 8K" ;;
        *) setup_mode="randrw"; setup_mode_name="随机读写 4K" ;;
    esac

    echo ""
    printf "  测试持续时间(秒) (默认300): "
    read -r setup_duration
    [ -z "$setup_duration" ] && setup_duration="300"

    # ========== 步骤 4/4: 配置确认 ==========
    echo ""
    echo -e "${BLUE}[步骤 4/4]${NC} 配置确认"
    echo ""
    echo "  ┌───────────────────────────────────────────┐"
    printf "  │  NFS服务器:  %-29s│\n" "${setup_nfs_server}:${setup_nfs_path}"
    printf "  │  NFS版本:    %-29s│\n" "v${setup_nfs_ver}"
    printf "  │  测试模式:   %-29s│\n" "$setup_mode_name"
    printf "  │  持续时间:   %-29s│\n" "${setup_duration} 秒"
    printf "  │  SSH端口:    %-29s│\n" "$setup_ssh_port"
    echo "  │                                           │"
    echo "  │  Worker列表:                              │"
    local idx=1
    for entry in "${setup_workers[@]}"; do
        local w_ip=$(echo "$entry" | awk '{print $1}')
        local w_site=$(echo "$entry" | awk '{print $3}')
        printf "  │  %d. %-17s Site %-2s ✅           │\n" "$idx" "$w_ip" "$w_site"
        idx=$((idx + 1))
    done
    echo "  └───────────────────────────────────────────┘"
    echo ""

    printf "  确认以上配置并开始测试? [Y/n]: "
    read -r confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        echo "  已取消"
        return 1
    fi

    # 保存配置到 hosts.txt
    {
        echo "# ============================================"
        echo "# 联想凌拓 NAS 性能测试工具 - 配置文件"
        echo "# 由配置向导自动生成于 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ============================================"
        echo "NFS_SERVER=$setup_nfs_server"
        echo "NFS_PATH=$setup_nfs_path"
        echo "NFS_VERSION=$setup_nfs_ver"
        echo "#"
        echo "# Worker列表: IP  密码  站点"
        for entry in "${setup_workers[@]}"; do
            echo "$entry"
        done
    } > "$CONFIG_FILE"

    echo ""
    echo -e "  ${GREEN}✅${NC} 配置已保存至 hosts.txt"

    # 设置全局参数
    MODE="$setup_mode"
    DURATION="$setup_duration"

    # 直接开始测试
    echo -e "  正在启动测试..."
    _run_full_test
}

# ========== 执行完整测试流程 ==========
_run_full_test() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  联想凌拓 NAS 性能测试工具 v${VERSION}${NC}"
    echo -e "${BOLD}============================================${NC}"
    TOTAL_STEPS=5
    check_sshpass
    parse_config
    check_workers
    deploy_workers
    mount_nfs
    run_benchmark
    collect_results
    print_summary "$LATEST_RUN_DIR"
    clean_workers
}

# ========== 命令行帮助 ==========
show_usage() {
    echo ""
    echo "联想凌拓 NAS 性能测试工具 v${VERSION}"
    echo ""
    echo "用法: ./nas_bench.sh <命令> [选项]"
    echo ""
    echo "命令:"
    echo "  setup     交互式配置向导 (推荐首次使用)"
    echo "  start     开始性能测试"
    echo "  check     仅检测Worker连通性"
    echo "  clean     清理远程测试数据"
    echo ""
    echo "选项:"
    echo "  --mode <randrw|seq|mixed>   测试模式 (默认: randrw)"
    echo "  --duration <秒>              持续时间 (默认: 300)"
    echo "  --port <端口>                SSH端口 (默认: 22)"
    echo "  --config <文件>              指定配置文件 (默认: hosts.txt)"
    echo ""
    echo "示例:"
    echo "  ./nas_bench.sh setup                        # 交互式配置并测试"
    echo "  ./nas_bench.sh start                        # 默认参数运行"
    echo "  ./nas_bench.sh start --mode seq --duration 600"
    echo "  ./nas_bench.sh check                        # 只检查连通性"
    echo ""
}

# ========== 主入口 ==========
COMMAND="${1:-}"
shift 2>/dev/null

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)     MODE="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --port)     SSH_PORT="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        *)          echo "未知选项: $1"; show_usage; exit 1 ;;
    esac
done

case "$COMMAND" in
    setup)
        interactive_setup
        ;;
    start)
        _run_full_test
        ;;
    check)
        TOTAL_STEPS=1
        check_sshpass
        parse_config
        check_workers
        ;;
    clean)
        TOTAL_STEPS=1
        check_sshpass
        parse_config
        check_workers
        clean_workers
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
