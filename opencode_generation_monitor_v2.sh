#!/bin/bash
# OpenCode 生成状态检测 - 改进版
# 1. 去掉线程数检测（MCP 进程可能一直开着线程）
# 2. 查询所有 session，而不仅是最新的一个

set -euo pipefail

OPENCODE_PID=$(pgrep -f "opencode web" | head -1 || echo "")
LOG_FILE="/data/.local/share/opencode/generation_monitor_v2.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# ==================== 获取所有 Session ID ====================
get_all_session_ids() {
    local sessions=$(curl -s http://127.0.0.1:18080/session 2>/dev/null)
    if [ -n "$sessions" ]; then
        # 提取所有 session ID
        echo "$sessions" | grep -o '"id":"ses_[^"]*"' | cut -d'"' -f4
    fi
}

# ==================== 获取 Session 详情 ====================
get_session_detail() {
    local session_id="$1"
    curl -s "http://127.0.0.1:18080/session/$session_id" 2>/dev/null
}

# ==================== 检查所有 Session 的活跃状态 ====================
check_all_sessions_activity() {
    local sessions=$(get_all_session_ids)
    local current_time=$(date +%s)000
    local has_active=0
    local active_sessions=""
    
    while IFS= read -r session_id; do
        [ -z "$session_id" ] && continue
        
        local detail=$(get_session_detail "$session_id")
        if [ -n "$detail" ]; then
            local updated=$(echo "$detail" | grep -o '"updated":[0-9]*' | head -1 | cut -d':' -f2)
            local title=$(echo "$detail" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4)
            
            if [ -n "$updated" ]; then
                local time_diff=$(( (current_time - updated) / 1000 ))
                
                # 如果 30 秒内有更新，认为是活跃的
                if [ "$time_diff" -lt 30 ]; then
                    has_active=1
                    active_sessions="${active_sessions}${session_id: -12}(更新于${time_diff}s前) "
                fi
            fi
        fi
    done <<< "$sessions"
    
    if [ $has_active -eq 1 ]; then
        echo "ACTIVE|$active_sessions"
        return 0
    else
        local session_count=$(echo "$sessions" | grep -c "ses_" || echo 0)
        echo "IDLE|${session_count}个session"
        return 1
    fi
}

# ==================== 检查上下文切换 ====================
check_context_switches() {
    if [ -z "$OPENCODE_PID" ] || [ ! -f "/proc/$OPENCODE_PID/status" ]; then
        echo "0"
        return
    fi
    
    grep "voluntary_ctxt_switches:" "/proc/$OPENCODE_PID/status" | awk '{print $2}'
}

# ==================== 检查 CPU 使用率 ====================
check_cpu_usage() {
    if [ -z "$OPENCODE_PID" ]; then
        echo "0"
        return
    fi
    
    # 采样两次取平均
    local cpu1=$(ps -p "$OPENCODE_PID" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
    sleep 1
    local cpu2=$(ps -p "$OPENCODE_PID" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
    
    echo "scale=2; ($cpu1 + $cpu2) / 2" | bc 2>/dev/null || echo "0"
}

# ==================== 检查网络传输 ====================
check_network_activity() {
    if [ -z "$OPENCODE_PID" ] || [ ! -f "/proc/$OPENCODE_PID/net/dev" ]; then
        echo "0"
        return
    fi
    
    local tx1=$(awk '/eth0|ens|enp/ {print $10}' "/proc/$OPENCODE_PID/net/dev" | head -1 || echo 0)
    sleep 2
    local tx2=$(awk '/eth0|ens|enp/ {print $10}' "/proc/$OPENCODE_PID/net/dev" | head -1 || echo 0)
    
    echo $(( (tx2 - tx1) / 2 ))
}

# ==================== 综合生成检测 ====================
is_generating_content() {
    local is_generating=0
    local reasons=""
    
    # 检测 1: 所有 Session 的活跃状态
    log "  检查所有 session..."
    local session_status=$(check_all_sessions_activity)
    local session_state=$(echo "$session_status" | cut -d'|' -f1)
    local session_info=$(echo "$session_status" | cut -d'|' -f2-)
    
    if [ "$session_state" = "ACTIVE" ]; then
        is_generating=1
        reasons="${reasons}session活跃($session_info) "
    fi
    
    # 检测 2: 上下文切换速率
    log "  检查上下文切换..."
    local current_ctx=$(check_context_switches)
    local ctx_file="/tmp/opencode_last_ctx"
    local prev_ctx=$(cat "$ctx_file" 2>/dev/null || echo "0")
    echo "$current_ctx" > "$ctx_file"
    
    if [ "$prev_ctx" != "0" ]; then
        local ctx_diff=$((current_ctx - prev_ctx))
        if [ "$ctx_diff" -gt 100 ]; then
            is_generating=1
            reasons="${reasons}上下文切换(${ctx_diff}) "
        fi
    fi
    
    # 检测 3: CPU 使用率（高负载）
    log "  检查 CPU..."
    local cpu=$(check_cpu_usage)
    if (( $(echo "$cpu > 15.0" | bc -l 2>/dev/null || echo "0") )); then
        is_generating=1
        reasons="${reasons}高CPU(${cpu}%) "
    fi
    
    # 检测 4: 网络传输
    log "  检查网络..."
    local net_rate=$(check_network_activity)
    if [ "$net_rate" -gt 5120 ]; then  # >5KB/s
        is_generating=1
        reasons="${reasons}网络流式(${net_rate}B/s) "
    fi
    
    if [ $is_generating -eq 1 ]; then
        echo "GENERATING|$reasons"
        return 0
    else
        echo "IDLE|CPU:${cpu}%"
        return 1
    fi
}

# ==================== 主程序 ====================
echo "========================================"
echo "🤖 OpenCode 生成状态检测器 v2.0"
echo "========================================"
echo ""
echo "改进:"
echo "  ✓ 查询所有 session，而不仅是最新"
echo "  ✓ 去掉线程数检测（MCP 干扰）"
echo "  ✓ 聚焦：session 更新、上下文切换、CPU、网络"
echo ""

if [ -z "$OPENCODE_PID" ]; then
    echo "❌ OpenCode 未运行"
    exit 1
fi

echo "OpenCode PID: $OPENCODE_PID"
echo ""

# 显示所有 session
echo "📋 当前所有 Session:"
SESSIONS=$(get_all_session_ids)
SESSION_COUNT=$(echo "$SESSIONS" | grep -c "ses_" || echo 0)
echo "  总数: $SESSION_COUNT"
echo ""

echo "$SESSIONS" | while IFS= read -r session_id; do
    [ -z "$session_id" ] && continue
    
    detail=$(get_session_detail "$session_id")
    if [ -n "$detail" ]; then
        title=$(echo "$detail" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4)
        updated=$(echo "$detail" | grep -o '"updated":[0-9]*' | head -1 | cut -d':' -f2)
        
        if [ -n "$updated" ]; then
            current=$(date +%s)000
            diff=$(( (current - updated) / 1000 ))
            
            # 如果最近 60 秒有更新，标记为活跃
            if [ "$diff" -lt 60 ]; then
                echo "  🔴 ${session_id: -12} - ${title: -30} (更新于 ${diff}s 前)"
            else
                echo "  🟢 ${session_id: -12} - ${title: -30} (${diff}s 前)"
            fi
        fi
    fi
done
echo ""

echo "========================================"
echo "🔍 实时监测生成状态（按 Ctrl+C 停止）"
echo "========================================"
echo ""

# 初始化上下文切换计数
CTX_INITIAL=$(check_context_switches)
echo "$CTX_INITIAL" > /tmp/opencode_last_ctx

while true; do
    STATUS=$(is_generating_content 2>&1 | tail -1)
    STATE=$(echo "$STATUS" | cut -d'|' -f1)
    REASON=$(echo "$STATUS" | cut -d'|' -f2-)
    
    TIMESTAMP=$(date '+%H:%M:%S')
    
    if [ "$STATE" = "GENERATING" ]; then
        echo "[$TIMESTAMP] 🔴 生成中 | $REASON"
    else
        echo "[$TIMESTAMP] 🟢 空闲   | $REASON"
    fi
    
    sleep 5
done