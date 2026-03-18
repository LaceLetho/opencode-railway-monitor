#!/bin/bash
# Test both monitoring methods - to be run inside the Railway container
# This compares: 1) Polling /session vs 2) SSE Event Stream

echo "==================================="
echo "OpenCode Monitoring Methods Test"
echo "==================================="
echo ""

# Configuration
API_URL="http://127.0.0.1:18080"
TEST_DURATION=10

echo "API Endpoint: $API_URL"
echo "Test Duration: ${TEST_DURATION}s"
echo ""

# ============================================
# METHOD 1: Polling /session endpoint
# ============================================
echo "--- Method 1: Polling /session ---"
echo "Querying session list..."

response=$(curl -s --max-time 10 "${API_URL}/session" 2>/dev/null || echo "FAILED")

if [ "$response" = "FAILED" ]; then
    echo "✗ FAILED: Cannot connect to API"
else
    # Parse with jq if available
    if command -v jq >/dev/null 2>&1; then
        session_count=$(echo "$response" | jq '. | length')
        echo "✓ SUCCESS: Found $session_count sessions"
        
        # Show first few sessions
        echo ""
        echo "First 5 sessions:"
        echo "$response" | jq -r '.[0:5] | .[] | "  - \(.id): updated=\(.updated)"'
        
        # Check for sessions updated recently
        current_time=$(date +%s)000
        threshold=$((10 * 60 * 1000))  # 10 minutes
        
        active_count=$(echo "$response" | jq "[.[] | select(.updated > ($current_time - $threshold))] | length")
        echo ""
        echo "Sessions active in last 10min: $active_count"
    else
        # Fallback to grep
        session_count=$(echo "$response" | grep -o '"id":"ses_' | wc -l)
        echo "✓ SUCCESS: Found $session_count sessions (jq not available)"
    fi
fi

echo ""

# ============================================
# METHOD 2: SSE Event Stream  
# ============================================
echo "--- Method 2: SSE Event Stream ---"
echo "Connecting to event stream for ${TEST_DURATION}s..."

event_file=$(mktemp)

# Start event capture in background
timeout $TEST_DURATION curl -N -s "${API_URL}/event" 2>/dev/null > "$event_file" &
curl_pid=$!

echo "Connected (PID: $curl_pid). Generating test activity..."

# Generate some activity while capturing
sleep 2
echo "  - Sending /session request..."
curl -s "${API_URL}/session" > /dev/null 2>&1

sleep 2
echo "  - Sending /global/health request..."
curl -s "${API_URL}/global/health" > /dev/null 2>&1

sleep 2
echo "  - Sending /agent request..."
curl -s "${API_URL}/agent" > /dev/null 2>&1

# Wait for capture to complete
wait $curl_pid 2>/dev/null

# Analyze events
echo ""
echo "Analyzing captured events..."

if [ -s "$event_file" ]; then
    line_count=$(wc -l < "$event_file" | tr -d ' ')
    echo "✓ Captured $line_count lines"
    
    # Extract event types
    echo ""
    echo "Event types detected:"
    grep "^event:" "$event_file" 2>/dev/null | sort | uniq -c | sort -rn | head -5
    
    # Check for activity events
    activity_count=$(grep -c "server\|session\|prompt\|message" "$event_file" 2>/dev/null || echo "0")
    echo ""
    echo "Activity-related events: $activity_count"
    
    # Show sample events
    echo ""
    echo "Sample events:"
    head -10 "$event_file"
else
    echo "✗ No events captured"
fi

# Cleanup
rm -f "$event_file"

echo ""

# ============================================
# COMPARISON
# ============================================
echo "--- Comparison ---"
echo ""
echo "Method 1: Polling /session"
echo "  ✓ Pro: Works with simple HTTP requests"
echo "  ✓ Pro: Can list all sessions"
echo "  ✗ Con: Limited to 100 sessions (API pagination)"
echo "  ✗ Con: 60s+ delay between checks"
echo "  ✗ Con: May miss active sessions not in top 100"
echo ""
echo "Method 2: SSE Event Stream"
echo "  ✓ Pro: Real-time (instant notification)"
echo "  ✓ Pro: Captures ALL activity (no session limit)"
echo "  ✓ Pro: Includes all event types (prompts, messages, etc.)"
echo "  ✗ Con: Requires persistent HTTP connection"
echo "  ✗ Con: Needs careful reconnection handling"
echo "  ✗ Con: SSE format requires parsing"
echo ""

# ============================================
# RECOMMENDATION
# ============================================
echo "--- Recommendation ---"
echo ""
echo "HYBRID APPROACH (Best of both):"
echo ""
echo "1. Use SSE Event Stream as PRIMARY detector:"
echo "   - Monitor /event endpoint continuously"
echo "   - Reset idle timer on ANY event"
echo "   - Low resource usage, real-time detection"
echo ""
echo "2. Use /session polling as BACKUP/FALLBACK:"
echo "   - Query every 5 minutes to verify"
echo "   - Check for sessions missed by SSE"
echo "   - Handle SSE disconnections"
echo ""
echo "This ensures:"
echo "  ✓ Immediate detection of activity via SSE"
echo "  ✓ Reliability via polling backup"
echo "  ✓ No missed sessions"
echo ""
