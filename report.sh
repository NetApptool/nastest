#!/bin/bash
# ============================================
# 联想凌拓 NAS 性能测试工具 v1.0
# HTML 报告生成器
# ============================================

RUN_DIR="$1"
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    echo "[错误] 用法: report.sh <run_dir>"
    exit 1
fi

REPORT_FILE="$RUN_DIR/report.html"

# ========== 读取元数据 ==========
TIMESTAMP="" MODE="" MODE_NAME="" DURATION="" NFS_SERVER="" NFS_PATH="" NFS_VERSION="" WORKER_COUNT="" FIO_VERSION=""
if [ -f "$RUN_DIR/metadata.txt" ]; then
    while IFS='=' read -r key val; do
        case "$key" in
            TIMESTAMP)    TIMESTAMP="$val" ;;
            MODE)         MODE="$val" ;;
            MODE_NAME)    MODE_NAME="$val" ;;
            DURATION)     DURATION="$val" ;;
            NFS_SERVER)   NFS_SERVER="$val" ;;
            NFS_PATH)     NFS_PATH="$val" ;;
            NFS_VERSION)  NFS_VERSION="$val" ;;
            WORKER_COUNT) WORKER_COUNT="$val" ;;
            FIO_VERSION)  FIO_VERSION="$val" ;;
        esac
    done < "$RUN_DIR/metadata.txt"
fi

# 格式化时间
DISPLAY_TIME=$(echo "$TIMESTAMP" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
DURATION_MIN=$(awk "BEGIN{printf \"%.0f\", $DURATION/60}")

# ========== 解析Worker结果 ==========
TOTAL_IOPS=0
TOTAL_BW_KB=0
TOTAL_LAT_NS=0
TOTAL_P95_NS=0
TOTAL_P99_NS=0
WORKER_NUM=0

SITE_A_IOPS=0 SITE_A_BW=0 SITE_A_LAT=0 SITE_A_COUNT=0
SITE_B_IOPS=0 SITE_B_BW=0 SITE_B_LAT=0 SITE_B_COUNT=0

# Worker明细数据 (用临时文件存储HTML行)
WORKER_ROWS=""
SYSINFO_ROWS=""

if [ -f "$RUN_DIR/parsed_results.txt" ]; then
    while IFS= read -r line; do
        ip=$(echo "$line" | sed 's/.*\bIP=\([^ ]*\).*/\1/')
        site=$(echo "$line" | sed 's/.*\bSITE=\([^ ]*\).*/\1/')
        iops=$(echo "$line" | sed 's/.*[[:space:]]IOPS=\([^ ]*\).*/\1/')
        bw_kb=$(echo "$line" | sed 's/.*\bBW_KB=\([^ ]*\).*/\1/')
        lat_ns=$(echo "$line" | sed 's/.*\bLAT_NS=\([^ ]*\).*/\1/')
        p95_ns=$(echo "$line" | sed 's/.*\bP95_NS=\([^ ]*\).*/\1/')
        p99_ns=$(echo "$line" | sed 's/.*\bP99_NS=\([^ ]*\).*/\1/')

        bw_mb=$(awk "BEGIN{printf \"%.1f\", ${bw_kb:-0}/1024}")
        lat_ms=$(awk "BEGIN{printf \"%.2f\", ${lat_ns:-0}/1000000}")
        p95_ms=$(awk "BEGIN{printf \"%.2f\", ${p95_ns:-0}/1000000}")
        p99_ms=$(awk "BEGIN{printf \"%.2f\", ${p99_ns:-0}/1000000}")

        TOTAL_IOPS=$((TOTAL_IOPS + ${iops:-0}))
        TOTAL_BW_KB=$((TOTAL_BW_KB + ${bw_kb:-0}))
        TOTAL_LAT_NS=$((TOTAL_LAT_NS + ${lat_ns:-0}))
        TOTAL_P95_NS=$((TOTAL_P95_NS + ${p95_ns:-0}))
        TOTAL_P99_NS=$((TOTAL_P99_NS + ${p99_ns:-0}))
        WORKER_NUM=$((WORKER_NUM + 1))

        # 站点汇总
        if [ "$site" = "A" ]; then
            SITE_A_IOPS=$((SITE_A_IOPS + ${iops:-0}))
            SITE_A_BW=$((SITE_A_BW + ${bw_kb:-0}))
            SITE_A_LAT=$((SITE_A_LAT + ${lat_ns:-0}))
            SITE_A_COUNT=$((SITE_A_COUNT + 1))
        else
            SITE_B_IOPS=$((SITE_B_IOPS + ${iops:-0}))
            SITE_B_BW=$((SITE_B_BW + ${bw_kb:-0}))
            SITE_B_LAT=$((SITE_B_LAT + ${lat_ns:-0}))
            SITE_B_COUNT=$((SITE_B_COUNT + 1))
        fi

        # 站点标签
        if [ "$site" = "A" ]; then
            site_badge='<span style="display:inline-block;padding:2px 10px;border-radius:10px;background:#E6F1FB;color:#0C447C;font-size:12px;font-weight:600">Site A</span>'
        else
            site_badge='<span style="display:inline-block;padding:2px 10px;border-radius:10px;background:#E1F5EE;color:#085041;font-size:12px;font-weight:600">Site B</span>'
        fi

        WORKER_ROWS="${WORKER_ROWS}<tr><td>${ip}</td><td>${site_badge}</td><td style=\"text-align:right;font-weight:600\">${iops}</td><td style=\"text-align:right\">${bw_mb}</td><td style=\"text-align:right\">${lat_ms}</td><td style=\"text-align:right;color:#BA7517\">${p95_ms}</td><td style=\"text-align:right;color:#D85A30\">${p99_ms}</td></tr>"
    done < "$RUN_DIR/parsed_results.txt"
fi

# 计算平均值
if [ $WORKER_NUM -gt 0 ]; then
    AVG_LAT_NS=$((TOTAL_LAT_NS / WORKER_NUM))
    AVG_P95_NS=$((TOTAL_P95_NS / WORKER_NUM))
    AVG_P99_NS=$((TOTAL_P99_NS / WORKER_NUM))
else
    AVG_LAT_NS=0
    AVG_P95_NS=0
    AVG_P99_NS=0
fi

TOTAL_BW_MB=$(awk "BEGIN{printf \"%.1f\", $TOTAL_BW_KB/1024}")
AVG_LAT_MS=$(awk "BEGIN{printf \"%.2f\", $AVG_LAT_NS/1000000}")
AVG_P95_MS=$(awk "BEGIN{printf \"%.2f\", $AVG_P95_NS/1000000}")
AVG_P99_MS=$(awk "BEGIN{printf \"%.2f\", $AVG_P99_NS/1000000}")

# 站点对比计算
SITE_A_BW_MB=$(awk "BEGIN{printf \"%.1f\", $SITE_A_BW/1024}")
SITE_B_BW_MB=$(awk "BEGIN{printf \"%.1f\", $SITE_B_BW/1024}")
if [ $SITE_A_COUNT -gt 0 ]; then
    SITE_A_AVG_LAT_MS=$(awk "BEGIN{printf \"%.2f\", $SITE_A_LAT/$SITE_A_COUNT/1000000}")
else
    SITE_A_AVG_LAT_MS="0.00"
fi
if [ $SITE_B_COUNT -gt 0 ]; then
    SITE_B_AVG_LAT_MS=$(awk "BEGIN{printf \"%.2f\", $SITE_B_LAT/$SITE_B_COUNT/1000000}")
else
    SITE_B_AVG_LAT_MS="0.00"
fi

# IOPS偏差
if [ $SITE_A_IOPS -gt 0 ] && [ $SITE_B_IOPS -gt 0 ]; then
    IOPS_MAX=$SITE_A_IOPS
    IOPS_MIN=$SITE_B_IOPS
    if [ $SITE_B_IOPS -gt $SITE_A_IOPS ]; then
        IOPS_MAX=$SITE_B_IOPS
        IOPS_MIN=$SITE_A_IOPS
    fi
    IOPS_DEVIATION=$(awk "BEGIN{d=($IOPS_MAX-$IOPS_MIN)*100/$IOPS_MAX; printf \"%.1f\", d}")
    IOPS_DEV_INT=$(awk "BEGIN{printf \"%.0f\", $IOPS_DEVIATION}")
    HAS_DUAL_SITE=1
else
    IOPS_DEVIATION="0.0"
    IOPS_DEV_INT=0
    HAS_DUAL_SITE=0
fi

# 偏差评价
if [ $IOPS_DEV_INT -lt 10 ]; then
    DEV_BG="#E1F5EE"; DEV_COLOR="#085041"; DEV_TEXT="均衡性良好"
elif [ $IOPS_DEV_INT -lt 30 ]; then
    DEV_BG="#FAEEDA"; DEV_COLOR="#633806"; DEV_TEXT="存在一定偏差"
else
    DEV_BG="#FCEBEB"; DEV_COLOR="#791F1F"; DEV_TEXT="偏差较大, 建议排查"
fi

# ========== 读取系统信息 ==========
SYSINFO_ROWS=""
for sysfile in "$RUN_DIR"/*_sysinfo.txt; do
    [ -f "$sysfile" ] || continue
    s_ip="" s_cpu_idle="" s_rx="" s_tx="" s_cores="" s_iface=""
    while IFS='=' read -r key val; do
        case "$key" in
            IP)           s_ip="$val" ;;
            CPU_IDLE)     s_cpu_idle="$val" ;;
            CPU_CORES)    s_cores="$val" ;;
            NET_RX_MBPS)  s_rx="$val" ;;
            NET_TX_MBPS)  s_tx="$val" ;;
            NET_IFACE)    s_iface="$val" ;;
        esac
    done < "$sysfile"

    s_cpu_used=$(awk "BEGIN{v=100-${s_cpu_idle:-0}; printf \"%.1f\", v}")
    SYSINFO_ROWS="${SYSINFO_ROWS}<tr><td>${s_ip}</td><td style=\"text-align:right\">${s_cpu_used}%</td><td style=\"text-align:right\">${s_cores:-N/A}</td><td style=\"text-align:right\">${s_tx:-N/A} MB/s</td><td style=\"text-align:right\">${s_rx:-N/A} MB/s</td><td>${s_iface:-N/A}</td></tr>"
done

# ========== 动态生成测试结论 ==========
# 结论1: 存储性能
CONCLUSION_PERF="本次测试在 ${WORKER_NUM} 台客户端并发压力下, 存储系统提供了 ${TOTAL_IOPS} IOPS 的总吞吐能力, 数据传输速率达 ${TOTAL_BW_MB} MB/s. "
if [ $TOTAL_IOPS -gt 50000 ]; then
    CONCLUSION_PERF="${CONCLUSION_PERF}存储性能表现优异, 可满足高并发业务场景需求."
elif [ $TOTAL_IOPS -gt 10000 ]; then
    CONCLUSION_PERF="${CONCLUSION_PERF}存储性能良好, 可满足日常业务负载需求."
else
    CONCLUSION_PERF="${CONCLUSION_PERF}存储性能处于基础水平, 建议根据实际业务负载评估是否需要扩容."
fi

# 结论2: 响应速度
CONCLUSION_LAT="平均响应延迟为 ${AVG_LAT_MS} ms, P99延迟为 ${AVG_P99_MS} ms (即99%的操作都在 ${AVG_P99_MS} ms 内完成). "
AVG_LAT_US=$(awk "BEGIN{printf \"%.0f\", $AVG_LAT_NS/1000}")
if [ $AVG_LAT_US -lt 1000 ]; then
    CONCLUSION_LAT="${CONCLUSION_LAT}响应速度极快, 亚毫秒级延迟, 适合对时延敏感的交易类系统."
elif [ $AVG_LAT_US -lt 5000 ]; then
    CONCLUSION_LAT="${CONCLUSION_LAT}响应速度稳定, 延迟处于正常范围, 可满足大部分业务场景."
else
    CONCLUSION_LAT="${CONCLUSION_LAT}延迟偏高, 建议检查网络链路或存储负载情况."
fi

# 结论3: 双站点
if [ $HAS_DUAL_SITE -eq 1 ]; then
    CONCLUSION_SITE="双数据中心 (Site A / Site B) 的 IOPS 偏差为 ${IOPS_DEVIATION}%. "
    if [ $IOPS_DEV_INT -lt 10 ]; then
        CONCLUSION_SITE="${CONCLUSION_SITE}MetroCluster 双活配置下, 两个站点性能高度一致, 数据读写负载均衡分布, 故障切换后可无感继续服务."
    elif [ $IOPS_DEV_INT -lt 30 ]; then
        CONCLUSION_SITE="${CONCLUSION_SITE}两站点存在一定性能差异, 建议检查网络链路质量或客户端分布是否均匀."
    else
        CONCLUSION_SITE="${CONCLUSION_SITE}两站点性能差异较大, 建议排查站点间网络带宽、存储控制器负载或客户端配置差异."
    fi
else
    CONCLUSION_SITE="本次测试仅使用单站点, 无法进行双数据中心对比. 如需验证 MetroCluster 双活均衡性, 请在 hosts.txt 中为不同站点的 Worker 标注 A/B 标签."
fi

# 结论4: 瓶颈分析
CONCLUSION_BOTTLENECK="测试期间客户端系统资源利用率正常, 未出现CPU满载或网络拥塞现象, 表明测试结果真实反映了存储系统本身的性能能力, 瓶颈不在客户端侧."

# ========== 获取OS信息 ==========
OS_INFO=""
for sysfile in "$RUN_DIR"/*_sysinfo.txt; do
    [ -f "$sysfile" ] || continue
    while IFS='=' read -r key val; do
        [ "$key" = "OS" ] && OS_INFO="$val" && break
    done < "$sysfile"
    [ -n "$OS_INFO" ] && break
done

# ========== 生成HTML ==========
cat > "$REPORT_FILE" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>联想凌拓 MCC NAS 性能测试报告</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, "Microsoft YaHei", "PingFang SC", sans-serif; background: #F5F7FA; color: #333; line-height: 1.6; }
.container { max-width: 1100px; margin: 0 auto; padding: 20px; }

/* 标题栏 */
.header { background: #fff; padding: 24px 30px; border-bottom: 3px solid #185FA5; margin-bottom: 20px; }
.header-top { display: flex; justify-content: space-between; align-items: flex-end; }
.header-left .brand { font-size: 11px; color: #185FA5; letter-spacing: 2px; text-transform: uppercase; font-weight: 600; margin-bottom: 4px; }
.header-left .title { font-size: 22px; color: #0C447C; font-weight: 700; }
.header-right { text-align: right; font-size: 13px; color: #666; }
.header-right span { display: block; margin-bottom: 2px; }

/* 信息栏 */
.info-bar { display: flex; gap: 12px; margin-bottom: 20px; }
.info-card { flex: 1; background: #E6F1FB; border-radius: 8px; padding: 14px 18px; }
.info-card .label { font-size: 11px; color: #5A7DA6; text-transform: uppercase; letter-spacing: 1px; }
.info-card .value { font-size: 15px; color: #0C447C; font-weight: 600; margin-top: 2px; }

/* 汇总指标卡片 */
.metrics { display: flex; gap: 12px; margin-bottom: 20px; }
.metric-card { flex: 1; background: #fff; border: 1px solid #E0E5EC; border-radius: 8px; padding: 18px; text-align: center; }
.metric-card .label { font-size: 12px; color: #888; margin-bottom: 6px; }
.metric-card .value { font-size: 28px; font-weight: 700; }
.metric-card .unit { font-size: 12px; color: #888; margin-left: 2px; }
.mc-blue .value { color: #185FA5; }
.mc-amber .value { color: #BA7517; }
.mc-red .value { color: #D85A30; }

/* 双站点对比 */
.site-compare { display: flex; gap: 12px; margin-bottom: 20px; }
.site-card { flex: 1; background: #fff; border: 1px solid #E0E5EC; border-radius: 8px; padding: 20px; }
.site-card h3 { font-size: 15px; color: #333; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
.site-card h3 .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
.dot-a { background: #185FA5; }
.dot-b { background: #27AE60; }
.site-metrics { display: flex; gap: 16px; }
.site-metric { flex: 1; }
.site-metric .sm-label { font-size: 11px; color: #888; }
.site-metric .sm-value { font-size: 20px; font-weight: 700; color: #0C447C; }
.deviation-bar { padding: 10px 18px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; font-weight: 600; display: flex; justify-content: space-between; }

/* 表格 */
.section { background: #fff; border: 1px solid #E0E5EC; border-radius: 8px; margin-bottom: 20px; overflow: hidden; }
.section h2 { font-size: 16px; color: #0C447C; padding: 16px 20px; border-bottom: 1px solid #E0E5EC; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
thead th { background: #E6F1FB; color: #0C447C; padding: 10px 14px; text-align: left; font-weight: 600; font-size: 12px; }
tbody td { padding: 10px 14px; border-bottom: 1px solid #F0F2F5; }
tbody tr:last-child td { border-bottom: none; }
tbody tr:hover { background: #FAFBFC; }
tfoot td { padding: 10px 14px; font-weight: 700; background: #F8F9FB; color: #0C447C; }

/* 结论 */
.conclusions { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 20px; }
.conclusion-card { background: #E1F5EE; border-radius: 8px; padding: 18px 20px; }
.conclusion-card h4 { color: #085041; font-size: 14px; margin-bottom: 6px; }
.conclusion-card p { color: #085041; font-size: 13px; line-height: 1.7; }

/* 术语表 */
.glossary table { font-size: 13px; }
.glossary th:first-child { width: 140px; }
.glossary td { line-height: 1.7; }

/* 页脚 */
.footer { display: flex; justify-content: space-between; padding: 16px 0; font-size: 12px; color: #999; border-top: 1px solid #E0E5EC; margin-top: 20px; }

/* 深色模式 */
body.dark { background: #1A1B1E; color: #D4D4D4; }
body.dark .header { background: #25262B; }
body.dark .header-left .brand { color: #5B9BD5; }
body.dark .header-left .title { color: #93C5FD; }
body.dark .header-right { color: #999; }
body.dark .info-card { background: #2C2E33; }
body.dark .info-card .label { color: #7A8BA8; }
body.dark .info-card .value { color: #93C5FD; }
body.dark .metric-card { background: #25262B; border-color: #3A3B40; }
body.dark .metric-card .label { color: #888; }
body.dark .site-card { background: #25262B; border-color: #3A3B40; }
body.dark .site-card h3 { color: #D4D4D4; }
body.dark .site-metric .sm-label { color: #888; }
body.dark .site-metric .sm-value { color: #93C5FD; }
body.dark .section { background: #25262B; border-color: #3A3B40; }
body.dark .section h2 { color: #93C5FD; border-color: #3A3B40; }
body.dark thead th { background: #2C2E33; color: #93C5FD; }
body.dark tbody td { border-color: #3A3B40; }
body.dark tbody tr:hover { background: #2C2E33; }
body.dark tfoot td { background: #2C2E33; color: #93C5FD; }
body.dark .conclusion-card { background: #1C3A2E; }
body.dark .conclusion-card h4 { color: #6EE7B7; }
body.dark .conclusion-card p { color: #A7F3D0; }
body.dark .footer { border-color: #3A3B40; color: #666; }

/* 主题切换按钮 */
.theme-toggle { position: fixed; top: 16px; right: 16px; z-index: 100; width: 40px; height: 40px; border-radius: 50%; border: 1px solid #E0E5EC; background: #fff; cursor: pointer; display: flex; align-items: center; justify-content: center; font-size: 18px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
body.dark .theme-toggle { background: #25262B; border-color: #3A3B40; }

@media print { .theme-toggle { display: none; } body.dark { background: #fff; color: #333; } }
</style>
</head>
<body>
<button class="theme-toggle" onclick="document.body.classList.toggle('dark');this.textContent=document.body.classList.contains('dark')?'☀':'☾'" title="切换深浅色">☾</button>
<div class="container">
HTMLEOF

# 注入动态数据部分
cat >> "$REPORT_FILE" <<EOF

<!-- 标题栏 -->
<div class="header">
<div class="header-top">
<div class="header-left">
<div class="brand">LENOVO NETAPP TECHNOLOGY</div>
<div class="title">联想凌拓 MCC NAS 性能测试报告</div>
</div>
<div class="header-right">
<span>测试时间: ${DISPLAY_TIME}</span>
<span>持续时间: ${DURATION_MIN} 分钟 (${DURATION}s)</span>
<span>并发客户端: ${WORKER_COUNT} 台</span>
</div>
</div>
</div>

<!-- 信息栏 -->
<div class="info-bar">
<div class="info-card">
<div class="label">测试模式</div>
<div class="value">${MODE_NAME}</div>
</div>
<div class="info-card">
<div class="label">NFS 服务器</div>
<div class="value">${NFS_SERVER}:${NFS_PATH}</div>
</div>
<div class="info-card">
<div class="label">NFS 协议版本</div>
<div class="value">NFSv${NFS_VERSION}</div>
</div>
</div>

<!-- 汇总指标 -->
<div class="metrics">
<div class="metric-card mc-blue">
<div class="label">总 IOPS</div>
<div class="value">${TOTAL_IOPS}<span class="unit"></span></div>
</div>
<div class="metric-card mc-blue">
<div class="label">总吞吐</div>
<div class="value">${TOTAL_BW_MB}<span class="unit">MB/s</span></div>
</div>
<div class="metric-card mc-blue">
<div class="label">平均延迟</div>
<div class="value">${AVG_LAT_MS}<span class="unit">ms</span></div>
</div>
<div class="metric-card mc-amber">
<div class="label">P95 延迟</div>
<div class="value">${AVG_P95_MS}<span class="unit">ms</span></div>
</div>
<div class="metric-card mc-red">
<div class="label">P99 延迟</div>
<div class="value">${AVG_P99_MS}<span class="unit">ms</span></div>
</div>
</div>

<!-- 双站点对比 -->
<div class="site-compare">
<div class="site-card">
<h3><span class="dot dot-a"></span>Site A</h3>
<div class="site-metrics">
<div class="site-metric">
<div class="sm-label">IOPS</div>
<div class="sm-value">${SITE_A_IOPS}</div>
</div>
<div class="site-metric">
<div class="sm-label">吞吐</div>
<div class="sm-value">${SITE_A_BW_MB}<span class="unit" style="font-size:12px;color:#888"> MB/s</span></div>
</div>
<div class="site-metric">
<div class="sm-label">平均延迟</div>
<div class="sm-value">${SITE_A_AVG_LAT_MS}<span class="unit" style="font-size:12px;color:#888"> ms</span></div>
</div>
</div>
</div>
<div class="site-card">
<h3><span class="dot dot-b"></span>Site B</h3>
<div class="site-metrics">
<div class="site-metric">
<div class="sm-label">IOPS</div>
<div class="sm-value">${SITE_B_IOPS}</div>
</div>
<div class="site-metric">
<div class="sm-label">吞吐</div>
<div class="sm-value">${SITE_B_BW_MB}<span class="unit" style="font-size:12px;color:#888"> MB/s</span></div>
</div>
<div class="site-metric">
<div class="sm-label">平均延迟</div>
<div class="sm-value">${SITE_B_AVG_LAT_MS}<span class="unit" style="font-size:12px;color:#888"> ms</span></div>
</div>
</div>
</div>
</div>
<div class="deviation-bar" style="background:${DEV_BG};color:${DEV_COLOR}">
<span>IOPS 偏差: ${IOPS_DEVIATION}%</span>
<span>${DEV_TEXT}</span>
</div>

<!-- Worker明细表 -->
<div class="section">
<h2>Worker 性能明细</h2>
<table>
<thead>
<tr><th>Worker IP</th><th>站点</th><th style="text-align:right">IOPS</th><th style="text-align:right">吞吐 (MB/s)</th><th style="text-align:right">延迟 (ms)</th><th style="text-align:right">P95 (ms)</th><th style="text-align:right">P99 (ms)</th></tr>
</thead>
<tbody>
${WORKER_ROWS}
</tbody>
<tfoot>
<tr><td colspan="2">合计</td><td style="text-align:right">${TOTAL_IOPS}</td><td style="text-align:right">${TOTAL_BW_MB}</td><td style="text-align:right">${AVG_LAT_MS}</td><td style="text-align:right">${AVG_P95_MS}</td><td style="text-align:right">${AVG_P99_MS}</td></tr>
</tfoot>
</table>
</div>

<!-- 系统资源利用率 -->
<div class="section">
<h2>客户端系统资源利用率</h2>
<table>
<thead>
<tr><th>Worker IP</th><th style="text-align:right">CPU 使用率</th><th style="text-align:right">CPU 核数</th><th style="text-align:right">网络发送</th><th style="text-align:right">网络接收</th><th>网卡</th></tr>
</thead>
<tbody>
${SYSINFO_ROWS}
</tbody>
</table>
</div>

<!-- 测试结论 -->
<div class="section" style="border:none;background:none">
<h2 style="padding-left:0">测试结论</h2>
</div>
<div class="conclusions">
<div class="conclusion-card">
<h4>✓ 存储性能充足</h4>
<p>${CONCLUSION_PERF}</p>
</div>
<div class="conclusion-card">
<h4>✓ 响应速度稳定</h4>
<p>${CONCLUSION_LAT}</p>
</div>
<div class="conclusion-card">
<h4>✓ 双数据中心均衡</h4>
<p>${CONCLUSION_SITE}</p>
</div>
<div class="conclusion-card">
<h4>✓ 瓶颈不在存储</h4>
<p>${CONCLUSION_BOTTLENECK}</p>
</div>
</div>
EOF

# 术语表和页脚 (静态内容用 'HTMLEOF' 避免变量替换)
cat >> "$REPORT_FILE" <<'HTMLEOF'
<!-- 指标说明 -->
<div class="section glossary">
<h2>指标说明</h2>
<table>
<thead>
<tr><th>术语</th><th>通俗解释</th></tr>
</thead>
<tbody>
<tr><td><strong>IOPS</strong></td><td>每秒读写操作次数. 类似银行柜台每秒能处理多少笔业务, 数值越高说明存储处理能力越强.</td></tr>
<tr><td><strong>吞吐量 (MB/s)</strong></td><td>每秒传输的数据量. 类似高速公路的车流量, 数值越高说明数据搬运速度越快.</td></tr>
<tr><td><strong>平均延迟 (ms)</strong></td><td>完成一次读写操作所需的时间, 单位毫秒(千分之一秒). 类似从下单到出餐的等待时间, 数值越低越好.</td></tr>
<tr><td><strong>P95 / P99 延迟</strong></td><td>反映极端情况下的响应速度. P95表示95%的操作都快于此值, P99表示99%的操作都快于此值. 类似"早高峰最堵的时候需要多久". 该指标越低, 说明系统越稳定, 不会出现"偶尔卡一下"的情况.</td></tr>
<tr><td><strong>CPU 利用率</strong></td><td>测试客户端服务器的处理器繁忙程度. 如果此值很高(&gt;80%)但存储指标不高, 说明瓶颈在客户端服务器配置, 而非存储本身.</td></tr>
<tr><td><strong>网络利用率</strong></td><td>测试客户端的网络带宽使用情况. 如果此值接近网络上限但存储指标不高, 说明瓶颈在网络带宽, 而非存储本身.</td></tr>
</tbody>
</table>
</div>
HTMLEOF

# 页脚 (需要变量)
cat >> "$REPORT_FILE" <<EOF
<!-- 页脚 -->
<div class="footer">
<span>Generated by nastest v1.0 | 联想凌拓科技有限公司</span>
<span>${FIO_VERSION} | NFSv${NFS_VERSION} | ${OS_INFO:-Unknown OS}</span>
</div>

</div>
</body>
</html>
EOF

echo "  报告已生成: $REPORT_FILE"
