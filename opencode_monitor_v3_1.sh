#!/bin/bash
# OpenCode Railway 智能监测 - v3.2
# 改进：1. 去掉线程数检测  2. 查询所有 session  3. 详细记录活跃session  4. 每分钟检查一次

set -euo pipefail

# ==================== 配置 ====================
IDLE_TIME_MINUTES=${IDLE_TIME_MINUTES:-10}
CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-60}
MEMORY_THRESHOLD_MB=${MEMORY_THRESHOLD_MB:-5000}
CPU_THRESHOLD_PERCENT=${CPU_THRESHOLD_PERCENT:-5.0}
GENERATION_GRACE_SECONDS=${GENERATION_GRACE_SECONDS:-60}
LOG_FILE="${LOG_FILE:-/tmp/opencode_monitor_script.log}"
STATE_DIR="/tmp/opencode_monitor_state_v3"
mkdir -p "$STATE_DIR"

LAST_GENERATION_FILE="$STATE_DIR/last_generation_time"
CONTEXT_SWITCH_FILE="$STATE_DIR/last_context_switches"

echo "========================================"
echo "🚂 OpenCode Railway 智能监测 v3.2"
echo "========================================"
echo ""
echo "改进:"
echo "  ✓ 去掉线程数检测（MCP 可能一直开着）"
echo "  ✓ 查询所有 session，不只是最新的"
echo "  ✓ 更准确的空闲判断"
echo ""
echo "配置:"
echo "  空闲时间: ${IDLE_TIME_MINUTES} 分钟"
echo "  内存阈值: ${MEMORY_THRESHOLD_MB} MB"
echo "  CPU阈值: ${CPU_THRESHOLD_PERCENT}%"
echo "  检查间隔: ${CHECK_INTERVAL_SECONDS} 秒 (约${CHECK_INTERVAL_SECONDS}秒)"
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

# ==================== 获取所有 Session ID ====================
get_all_session_ids() {
    curl -s http://127.0.0.1:18080/session 2>/dev/null | grep -o '"id":"ses_[^"]*"' | cut -d'"' -f4
}

# ==================== 检查所有 Session 是否都空闲 ====================
are_all_sessions_idle() {
    local sessions=$(get_all_session_ids)
    local current_time=$(date +%s)000
    local threshold=$((IDLE_TIME_MINUTES * 60 * 1000))
    local active_count=0
    local total_count=0
    local active_sessions_info=""
    
    while IFS= read -r session_id; do
        [ -z "$session_id" ] && continue
        total_count=$((total_count + 1))
        
        local detail=$(curl -s "http://127.0.0.1:18080/session/$session_id" 2>/dev/null)
        if [ -n "$detail" ]; then
            local updated=$(echo "$detail" | grep -o '"updated":[0-9]*' | head -1 | cut -d':' -f2)
            local title=$(echo "$detail" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4)
            local directory=$(echo "$detail" | grep -o '"directory":"[^"]*"' | head -1 | cut -d'"' -f4)
            
            if [ -n "$updated" ]; then
                local time_diff=$((current_time - updated))
                local time_diff_sec=$((time_diff / 1000))
                # 如果在阈值内有更新，认为是活跃的
                if [ "$time_diff" -lt "$threshold" ]; then
                    active_count=$((active_count + 1))
                    # 记录活跃 session 的信息
                    active_sessions_info="${active_sessions_info}${session_id: -8}|${time_diff_sec}s|${title}|${directory}; "
                fi
            fi
        fi
    done <<< "$sessions"
    
    log "  Session统计: 总共${total_count}个, 活跃${active_count}个"
    
    # 如果有活跃的 session，记录详细信息
    if [ -n "$active_sessions_info" ]; then
        log "  🔴 活跃Session详情: ${active_sessions_info}"
    fi
    
    # 如果有活跃的 session，返回 false（不空闲）
    if [ "$active_count" -gt 0 ]; then
        return 1  # 不空闲
    else
        return 0  # 全部空闲
    fi
}

# ==================== 检测是否正在生成内容 ====================
is_generating_content() {
    local pid=$(get_opencode_pid)
    [ -z "$pid" ] && echo "NO_PID" && return 1
    
    local is_generating=0
    local reasons=""
    
    # 检测 1: 检查所有 session 的活跃状态
    local sessions=$(get_all_session_ids)
    local current_time=$(date +%s)000
    
    while IFS= read -r session_id; do
        [ -z "$session_id" ] && continue
        
        local detail=$(curl -s "http://127.0.0.1:18080/session/$session_id" 2>/dev/null)
        if [ -n "$detail" ]; then
            local updated=$(echo "$detail" | grep -o '"updated":[0-9]*' | head -1 | cut -d':' -f2)
            if [ -n "$updated" ]; then
                local time_diff=$(( (current_time - updated) / 1000 ))
                # 如果 15 秒内有更新，认为是正在生成
                if [ "$time_diff" -lt 15 ]; then
                    is_generating=1
                    reasons="${reasons}session更新(${session_id: -8}, ${time_diff}s) "
                    break
                fi
            fi
        fi
    done <<< "$sessions"
    
    # 检测 2: 上下文切换速率
    if [ -f "/proc/$pid/status" ]; then
        local current_ctx=$(grep "voluntary_ctxt_switches:" "/proc/$pid/status" | awk '{print $2}' | tr -d ' \n\t')
        local prev_ctx=$(cat "$CONTEXT_SWITCH_FILE" 2>/dev/null | tr -d ' \n\t' || echo "0")
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
    
    # 检测 3: 高 CPU（去掉线程数检测）
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
    if (( $(echo "$cpu > 25.0" | bc -l 2>/dev/null || echo "0") )); then
        is_generating=1
        reasons="${reasons}高CPU(${cpu}%) "
        date +%s > "$LAST_GENERATION_FILE"
    fi
    
    # 检测 4: 冷却期
    if [ -f "$LAST_GENERATION_FILE" ]; then
        local last_gen=$(cat "$LAST_GENERATION_FILE")
        local current=$(date +%s)
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
    local pid=$(get_opencode_pid)
    [ -z "$pid" ] && echo "0" && return
    
    local total_kb=0
    
    if [ -f "/proc/$pid/status" ]; then
        local main_mem=$(grep VmRSS "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        total_kb=$((total_kb + main_mem))
    fi
    
    local other_mem=$(ps aux | grep -E 'playwright-mcp|mcp-remote|language-server|tsserver' | grep -v grep | awk '{sum+=$6} END {print sum}' || echo 0)
    total_kb=$((total_kb + other_mem))
    
    echo $((total_kb / 1024))
}

# ==================== 重启 ====================
restart_opencode() {
    local reason="$1"
    local mem_before=$(get_memory_mb)
    
    log "========================================"
    log "🔄 重启 OpenCode"
    log "  原因: $reason"
    log "  重启前内存: ${mem_before}MB"
    
    rm -f "$LAST_GENERATION_FILE" "$CONTEXT_SWITCH_FILE"
    
    local wrapper_pid=1
    local opencode_pid=$(get_opencode_pid)
    
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
    log "🚀 监测服务启动 v3.2"
    
    local start_time=$(date +%s)
    local consecutive_checks=0
    local check_count=0
    
    # 初始化
    local pid=$(get_opencode_pid)
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        grep "voluntary_ctxt_switches:" "/proc/$pid/status" | awk '{print $2}' | tr -d ' \n\t' > "$CONTEXT_SWITCH_FILE"
    fi
    
    while true; do
        check_count=$((check_count + 1))
        
        local pid=$(get_opencode_pid)
        if [ -z "$pid" ]; then
            sleep $CHECK_INTERVAL_SECONDS
            continue
        fi
        
        local current_mem=$(get_memory_mb)
        local uptime=$(($(date +%s) - start_time))
        local uptime_hours=$((uptime / 3600))
        
        # 显示所有 session 状态（每5次检查显示一次，即每5分钟）
        if [ $((check_count % 5)) -eq 1 ]; then
            log "⏱️ ${uptime_hours}h | 内存:${current_mem}MB"
            are_all_sessions_idle  # 这会输出 session 统计
        fi
        
        # 检查生成状态
        local gen_status=$(is_generating_content)
        local gen_state=$(echo "$gen_status" | cut -d'|' -f1)
        local gen_info=$(echo "$gen_status" | cut -d'|' -f2-)
        
        # 如果正在生成，重置计数
        if [ "$gen_state" = "GENERATING" ]; then
            if [ $consecutive_checks -gt 0 ]; then
                log "  📝 生成中: $gen_info"
            fi
            consecutive_checks=0
            sleep $CHECK_INTERVAL_SECONDS
            continue
        fi
        
        # 检查所有 session 是否都空闲
        if are_all_sessions_idle; then
            consecutive_checks=$((consecutive_checks + 1))
            local idle_min=$((consecutive_checks * CHECK_INTERVAL_SECONDS / 60))
            
            # 只有所有 session 空闲 AND 内存超过 2GB 时才重启
            if [ $idle_min -ge $IDLE_TIME_MINUTES ] && [ "$current_mem" -gt 2000 ]; then
                log "💤 所有 Session 空闲 ${IDLE_TIME_MINUTES} 分钟 且 内存占用 ${current_mem}MB > 2GB，执行重启"
                restart_opencode "空闲且高内存"
            elif [ $((check_count % 5)) -eq 0 ]; then
                if [ "$current_mem" -gt 2000 ]; then
                    log "  🟢 全部空闲 (${idle_min}/${IDLE_TIME_MINUTES} 分钟), 内存: ${current_mem}MB (已超2GB)"
                else
                    log "  🟢 全部空闲 (${idle_min}/${IDLE_TIME_MINUTES} 分钟), 内存: ${current_mem}MB"
                fi
            fi
        else
            consecutive_checks=0
        fi
        
        sleep $CHECK_INTERVAL_SECONDS
    done
}

trap 'log "🛑 监测退出"; exit 0' SIGINT SIGTERM
main "$@"