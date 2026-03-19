#!/bin/bash
# OpenCode Railway 智能监测 - v4.0 (SSE Only)
# 改进：使用SSE事件流作为唯一检测器

set -uo pipefail

# ==================== 配置 ====================
IDLE_TIME_MINUTES=${IDLE_TIME_MINUTES:-10}
CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-60}
MEMORY_THRESHOLD_MB=${MEMORY_THRESHOLD_MB:-5000}
CPU_THRESHOLD_PERCENT=${CPU_THRESHOLD_PERCENT:-5.0}
GENERATION_GRACE_SECONDS=${GENERATION_GRACE_SECONDS:-60}
LOG_FILE="${LOG_FILE:-/tmp/opencode_monitor_script.log}"
STATE_DIR="/tmp/opencode_monitor_state_v4"
mkdir -p "$STATE_DIR"

LAST_ACTIVITY_FILE="$STATE_DIR/last_activity"
LAST_GENERATION_FILE="$STATE_DIR/last_generation_time"
CONTEXT_SWITCH_FILE="$STATE_DIR/last_context_switches"
EVENT_MONITOR_PID_FILE="$STATE_DIR/event_monitor.pid"

API_URL="http://127.0.0.1:18080"

echo "========================================"
echo "🚂 OpenCode Railway 智能监测 v4.0"
echo "========================================"
echo ""
echo "重大改进:"
echo "  ✓ 使用SSE事件流 - 实时检测活动"
echo ""
echo "配置:"
echo "  空闲时间: ${IDLE_TIME_MINUTES} 分钟"
echo "  内存阈值: ${MEMORY_THRESHOLD_MB} MB"
echo "  CPU阈值: ${CPU_THRESHOLD_PERCENT}%"
echo "  检查间隔: ${CHECK_INTERVAL_SECONDS} 秒"
echo "  日志文件: ${LOG_FILE}"
echo "========================================"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

get_opencode_pid() {
    pgrep -f "opencode web" | head -1 || echo ""
}

# ==================== 方法1: SSE事件流监控 ====================
start_event_monitor() {
    log "🔄 启动SSE事件流监控..."
    
    # 后台运行事件监控
    (
        while true; do
            log "  [SSE] 连接到事件流..."
            
            # 连接到SSE端点，捕获活动事件
            curl -N -s "${API_URL}/event" 2>/dev/null | while read -r line; do
                # 只检测真正的用户活动事件，过滤系统心跳
                if echo "$line" | grep -qE "data:"; then
                    # 过滤掉系统心跳和连接事件
                    if ! echo "$line" | grep -qE '"type":"server\.(heartbeat|connected)"'; then
                        # 有真正的活动！更新时间戳
                        date +%s > "$LAST_ACTIVITY_FILE"
                        log "  [SSE] 用户活动: $line"
                    fi
                fi
            done
            
            # 如果连接断开，等待后重连
            log "  [SSE] 连接断开，5秒后重连..."
            sleep 5
        done
    ) &
    
    local pid=$!
    echo $pid > "$EVENT_MONITOR_PID_FILE"
    log "  [SSE] 事件监控已启动 (PID: $pid)"
}

stop_event_monitor() {
    if [ -f "$EVENT_MONITOR_PID_FILE" ]; then
        local pid=$(cat "$EVENT_MONITOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "  [SSE] 事件监控已停止"
        fi
        rm -f "$EVENT_MONITOR_PID_FILE"
    fi
}

# ==================== 活动检测 ====================
is_generating_content() {
    local pid
    pid=$(get_opencode_pid)
    [ -z "$pid" ] && echo "NO_PID" && return 1
    
    local is_generating=0
    local reasons=""
    
    # 检测 1: SSE活动（检查最后活动时间）
    if [ -f "$LAST_ACTIVITY_FILE" ]; then
        local last_activity=$(cat "$LAST_ACTIVITY_FILE")
        local current=$(date +%s)
        local time_since_activity=$((current - last_activity))
        
        if [ "$time_since_activity" -lt 15 ]; then
            is_generating=1
            reasons="${reasons}SSE活动(${time_since_activity}s) "
            date +%s > "$LAST_GENERATION_FILE"
        fi
    fi
    
    # 检测 2: 上下文切换速率
    if [ -f "/proc/$pid/status" ]; then
        local current_ctx
        current_ctx=$(grep "voluntary_ctxt_switches:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' | tr -d ' \n\t' || echo "0")
        local prev_ctx
        prev_ctx=$(cat "$CONTEXT_SWITCH_FILE" 2>/dev/null | tr -d ' \n\t' || echo "0")
        echo "$current_ctx" > "$CONTEXT_SWITCH_FILE"
        
        if [ "$prev_ctx" != "0" ] && [ -n "$current_ctx" ] && [ -n "$prev_ctx" ]; then
            local ctx_diff=$((current_ctx - prev_ctx))
            if [ "$ctx_diff" -gt 100 ]; then
                is_generating=1
                reasons="${reasons}上下文切换(${ctx_diff}) "
                date +%s > "$LAST_GENERATION_FILE"
            fi
        fi
    fi
    
    # 检测 3: 高 CPU
    local cpu
    cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
    if awk "BEGIN {exit !($cpu > 25.0)}" 2>/dev/null; then
        is_generating=1
        reasons="${reasons}高CPU(${cpu}%) "
        date +%s > "$LAST_GENERATION_FILE"
    fi
    
    # 检测 4: 冷却期
    if [ -f "$LAST_GENERATION_FILE" ]; then
        local last_gen
        last_gen=$(cat "$LAST_GENERATION_FILE")
        local current
        current=$(date +%s)
        local time_since_gen=$((current - last_gen))
        if [ "$time_since_gen" -lt "$GENERATION_GRACE_SECONDS" ]; then
            is_generating=1
            reasons="${reasons}冷却期(${time_since_gen}s) "
        fi
    fi
    
    if [ $is_generating -eq 1 ]; then
        echo "GENERATING|$reasons"
        return 0
    else
        echo "IDLE|CPU:${cpu}%"
        return 1
    fi
}

# ==================== 获取内存使用 ====================
get_memory_mb() {
    # 统计所有用户进程的 RSS 总和
    local total_kb=$(ps aux | awk 'NR>1 {sum+=$6} END {print sum}' 2>/dev/null || echo 0)
    echo $((total_kb / 1024))
}

# ==================== 重启 ====================
restart_opencode() {
    local reason="$1"
    local mem_before
    mem_before=$(get_memory_mb)
    
    log "========================================"
    log "🔄 重启 OpenCode"
    log "  原因: $reason"
    log "  重启前内存: ${mem_before}MB"
    
    stop_event_monitor
    
    rm -f "$LAST_GENERATION_FILE" "$CONTEXT_SWITCH_FILE" "$LAST_ACTIVITY_FILE"
    
    local wrapper_pid=1
    local opencode_pid
    opencode_pid=$(get_opencode_pid)
    
    log "  优雅关闭..."
    if [ -n "$opencode_pid" ]; then
        kill -TERM "$opencode_pid" 2>/dev/null || true
    fi
    
    sleep 5
    
    if pgrep -f "opencode web" > /dev/null 2>&1; then
        log "  强制终止..."
        killall -9 opencode 2>/dev/null || true
        killall -9 bun 2>/dev/null || true
    fi
    
    killall -9 node 2>/dev/null || true
    
    log "  触发重新部署..."
    kill -9 $wrapper_pid 2>/dev/null || true
    exit 0
}

# ==================== 主循环 ====================
main() {
    log "🚀 监测服务启动 v4.0 (SSE 模式)"
    
    local start_time
    start_time=$(date +%s)
    local consecutive_checks=0
    local check_count=0
    
    # 初始化
    local pid
    pid=$(get_opencode_pid)
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        grep "voluntary_ctxt_switches:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' | tr -d ' \n\t' > "$CONTEXT_SWITCH_FILE" || true
    fi
    
    # 初始化活动时间
    date +%s > "$LAST_ACTIVITY_FILE"
    
    # 启动SSE事件监控
    start_event_monitor
    
    while true; do
        check_count=$((check_count + 1))
        
        pid=$(get_opencode_pid)
        if [ -z "$pid" ]; then
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi
        
        local current_mem
        current_mem=$(get_memory_mb)
        local uptime
        uptime=$(($(date +%s) - start_time))
        local uptime_hours=$((uptime / 3600))
        
        # 显示状态（每5次检查）
        if [ $((check_count % 5)) -eq 1 ]; then
            log "⏱️ ${uptime_hours}h | 内存:${current_mem}MB"
            
            if [ -f "$LAST_ACTIVITY_FILE" ]; then
                local last_activity=$(cat "$LAST_ACTIVITY_FILE")
                local current=$(date +%s)
                local time_diff=$((current - last_activity))
                log "  [SSE] 最后活动: ${time_diff}s 前"
            fi
        fi
        
        # 检查生成状态
        local gen_status
        gen_status=$(is_generating_content)
        local gen_state
        gen_state=$(echo "$gen_status" | cut -d'|' -f1)
        local gen_info
        gen_info=$(echo "$gen_status" | cut -d'|' -f2-)
        
        # 如果正在生成，重置计数
        if [ "$gen_state" = "GENERATING" ]; then
            if [ $consecutive_checks -gt 0 ]; then
                log "  📝 生成中: $gen_info"
            fi
            consecutive_checks=0
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi
        
        # 检查是否空闲
        if [ -f "$LAST_ACTIVITY_FILE" ]; then
            local last_activity=$(cat "$LAST_ACTIVITY_FILE")
            local current=$(date +%s)
            local idle_time=$(( (current - last_activity) / 60 ))
            
            if [ $idle_time -ge "$IDLE_TIME_MINUTES" ] && [ "$current_mem" -gt 2000 ]; then
                log "💤 空闲 ${IDLE_TIME_MINUTES} 分钟且内存占用 ${current_mem}MB > 2GB，执行重启"
                restart_opencode "空闲且高内存"
            elif [ $((check_count % 5)) -eq 0 ]; then
                log "  🟢 全部空闲 (${idle_time}/${IDLE_TIME_MINUTES} 分钟), 内存: ${current_mem}MB"
            fi
        fi
        
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

trap 'log "🛑 监测退出"; stop_event_monitor; exit 0' SIGINT SIGTERM
main "$@"
