# OpenCode Railway Monitor

智能监测 OpenCode 内存使用，在 Railway 环境中自动检测 Session 空闲状态并在适当时机重启服务。

## 🎯 项目简介

OpenCode 是一个强大的 AI 编程助手，但在长时间运行后会出现内存泄漏问题：
- 每个 Session 独立启动 MCP 进程，占用大量内存
- Session 数据持续累积，数据库不断增长
- 虚拟内存异常膨胀，最终达到 6GB+ 导致崩溃

本项目提供智能监测脚本，能够：
- **检测所有 Session 的活跃状态**（不是只看最新的一个）
- **识别大模型是否正在生成内容**（避免中断生成过程）
- **详细记录活跃 Session 的信息**（ID、更新时间、标题、目录）
- **只在真正空闲时自动重启**（不影响用户使用）
- **节省内存并延长服务稳定运行时间**

## 📊 内存问题背景

### 已知问题
根据 OpenCode GitHub Issues（#13041, #16697, #15326），这是一个架构层面的问题：
- 每个 Session 独立启动 MCP 服务器和 LSP 进程
- 切换 Workspace 时，旧进程不会关闭
- 空闲 Session 数据不会自动清理

### 内存占用分析
```
优化前：
- MCP 进程：22 个
- 总内存：~1.2 GB
- OpenCode RSS：432 MB
- 虚拟内存：71 GB（异常！）

优化后（重启后）：
- MCP 进程：2 个
- 总内存：~10 MB
- OpenCode RSS：9 MB
```

## 🔍 检测原理

### 1. 全局 SSE 事件流监控

连接 `/global/event` SSE 端点，实时接收所有活动事件：
```bash
curl -N http://127.0.0.1:18080/global/event
```

**事件类型**：
- `message.part.updated` - 消息更新（用户输入、AI回复）
- `tool.*` - 工具调用状态变化
- `server.*` - 服务器状态（过滤掉心跳和连接事件）

**判定逻辑**：
- 🔴 活跃：15 秒内收到非系统事件
- 🟢 空闲：超过 10 分钟无事件

### 2. 辅助检测机制

作为 SSE 的补充，同时检测：
- **上下文切换速率** - `/proc/[pid]/status` 的 `voluntary_ctxt_switches`
- **CPU 使用率** - `ps -o %cpu` > 25%
- **冷却期保护** - 生成后等待 60 秒

### 3. 大模型生成状态检测

避免在 AI 生成内容时重启：

| 检测方法 | 原理 | 阈值 |
|---------|------|------|
| **Session 更新时间** | API `/session/{id}` 的 `updated` 字段 | < 15 秒 |
| **上下文切换速率** | `/proc/[pid]/status` 的 `voluntary_ctxt_switches` | > 100 次/周期 |
| **CPU 使用率** | `ps -o %cpu` | > 25% |
| **冷却期保护** | 生成后等待时间 | 60 秒 |

**注意**：不检测线程数，因为 MCP 进程可能一直开着线程。

### 4. 空闲判定标准

**系统空闲（必须同时满足）**：
- ✅ 所有 Session 都超过 IDLE_TIME_MINUTES（默认 10 分钟）未更新
- ✅ 没有在生成内容（CPU < 25%，无上下文切换激增）
- ✅ 不在冷却期（上次生成后 60 秒）

**重启条件（满足任一）**：
- 🔄 所有 Session 空闲达到 IDLE_TIME_MINUTES
- 🔄 内存使用超过 MEMORY_THRESHOLD_MB（默认 5000MB）

## 📁 文件说明

```
.
├── opencode_monitor_v4.sh           # ⭐ 智能监测主脚本 v4.0（推荐）- SSE + 轮询混合模式
├── README.md                        # 本文档
└── LICENSE                          # MIT 许可证
```

### 主脚本：opencode_monitor_v4.sh

**功能**：
- 🔄 **全局 SSE 事件流监控** - 连接 `/global/event` 实时检测所有活动
- 🔄 **多维度活跃检测** - SSE 事件 + CPU + 上下文切换
- 🔄 **智能进程识别** - 正确匹配 OpenCode 工作进程（非 wrapper）
- 🔄 **每 60 秒检查一次系统状态**
- 🔄 **检测大模型是否正在生成内容**
- 🔄 **内存超过阈值或空闲超时时自动重启**
- 🔄 **Railway API 集成** - 支持部署重启和重新部署

**配置参数**：
```bash
IDLE_TIME_MINUTES=10          # Session 空闲时间阈值（分钟）
CHECK_INTERVAL_SECONDS=60     # 检查间隔（秒），默认每分钟
MEMORY_THRESHOLD_MB=5000      # 内存上限（MB），默认 5GB
CPU_THRESHOLD_PERCENT=5.0     # CPU 空闲阈值（%）
GENERATION_GRACE_SECONDS=60   # 生成后冷却期（秒）
```

## 🚀 使用方法

### 1. 克隆仓库

```bash
git clone https://github.com/LaceLetho/opencode-railway-monitor.git
cd opencode-railway-monitor
```

### 2. 启动监测（推荐后台运行）

```bash
# 方式 1：后台运行（推荐）
nohup ./opencode_monitor_v4.sh > /tmp/opencode_monitor.log 2>&1 &
echo $! > ~/.opencode_monitor.pid

# 方式 2：前台运行（调试用）
./opencode_monitor_v4.sh

# 方式 3：自定义参数
IDLE_TIME_MINUTES=15 MEMORY_THRESHOLD_MB=4000 ./opencode_monitor_v4.sh
```

### 3. 查看日志

```bash
# 实时查看日志
tail -f /tmp/opencode_monitor.log

# 查看完整日志
cat /data/.local/share/opencode/auto_restart_v3.log
```

### 4. 停止监测

```bash
# 方式 1：通过 PID 文件
kill $(cat ~/.opencode_monitor.pid) 2>/dev/null

# 方式 2：直接查找进程
pkill -f opencode_monitor_v4
```

### 5. 使用 systemd 服务（长期运行）

```bash
# 创建服务文件
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/opencode-monitor.service << 'SERVICE'
[Unit]
Description=OpenCode Railway Monitor
After=network.target

[Service]
Type=simple
ExecStart=/path/to/opencode-railway-monitor/opencode_monitor_v4.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SERVICE

# 启用并启动服务
systemctl --user daemon-reload
systemctl --user enable opencode-monitor
systemctl --user start opencode-monitor

# 查看状态
systemctl --user status opencode-monitor
journalctl --user -u opencode-monitor -f
```

## 📊 日志示例

```
[2026-03-17 09:38:43] 🚀 监测服务启动 v3.2
[2026-03-17 09:38:43] ⏱️ 0h | 内存:1350MB
[2026-03-17 09:38:44]   Session统计: 总共100个, 活跃1个
[2026-03-17 09:38:44]   🔴 活跃Session详情: 4Wg5ULGq|5s|OpenCode proxy wrapper memory usage|/data/workspace; 
[2026-03-17 09:39:02] 🚀 监测服务启动 v3.2
[2026-03-17 09:39:02] ⏱️ 0h | 内存:1350MB
[2026-03-17 09:39:03]   Session统计: 总共100个, 活跃1个
[2026-03-17 09:39:03]   🔴 活跃Session详情: 4Wg5ULGq|8s|OpenCode proxy wrapper memory usage|/data/workspace; 
...
```

## ⚙️ 配置选项

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `IDLE_TIME_MINUTES` | 10 | Session 空闲时间阈值（分钟） |
| `CHECK_INTERVAL_SECONDS` | 60 | 检查间隔（秒），默认每分钟 |
| `MEMORY_THRESHOLD_MB` | 5000 | 内存上限（MB），默认 5GB |
| `CPU_THRESHOLD_PERCENT` | 5.0 | CPU 空闲阈值（%） |
| `GENERATION_GRACE_SECONDS` | 60 | 生成后冷却期（秒） |

### 调整示例

```bash
# 更激进的策略（5分钟空闲就重启，内存限制4GB，每30秒检查一次）
IDLE_TIME_MINUTES=5 CHECK_INTERVAL_SECONDS=30 MEMORY_THRESHOLD_MB=4000 ./opencode_monitor_v3_1.sh

# 更保守的策略（20分钟空闲，内存限制6GB，每2分钟检查一次）
IDLE_TIME_MINUTES=20 CHECK_INTERVAL_SECONDS=120 MEMORY_THRESHOLD_MB=6000 ./opencode_monitor_v3_1.sh
```

## 🔧 工作原理详解

### Railway 环境特殊处理

由于 Railway 使用容器化部署：

```
进程结构：
PID 1: node /app/server.js (Railway Wrapper)
  └─ PID 9: bunx opencode web (OpenCode)
      └─ LSP/MCP 子进程
```

**重启机制**：
1. 优雅关闭 OpenCode (`SIGTERM`)
2. 等待 5 秒
3. 强制清理残留进程 (`killall -9`)
4. 杀死 Railway Wrapper (PID 1)
5. Railway 自动重新部署容器

### Session 查询 API

```bash
# 获取所有 Session
curl http://127.0.0.1:18080/session

# 获取特定 Session 详情
curl http://127.0.0.1:18080/session/{session_id}
```

响应示例：
```json
[{
  "id": "ses_305c50033ffe5vYjEL4Wg5ULGq",
  "title": "OpenCode proxy wrapper memory usage",
  "updated": 1773732198867
}]
```

## 🐛 故障排查

### 脚本无法启动

```bash
# 检查权限
chmod +x opencode_monitor_v4.sh

# 检查依赖
which curl bc jq python3

# 检查 OpenCode 是否运行
pgrep -f "opencode web"
```

### 检测不准确

```bash
# 手动测试 Session 查询
curl -s http://127.0.0.1:18080/session | head -c 500

# 查看当前 Session 数量
curl -s http://127.0.0.1:18080/session | grep -o '"id":"ses_' | wc -l
```

### 无法重启

检查 Railway 环境变量：
```bash
echo $RAILWAY_SERVICE_NAME
echo $RAILWAY_ENVIRONMENT
```

## 📚 相关资源

- [OpenCode GitHub Issues - Memory Leaks](https://github.com/anomalyco/opencode/issues?q=is%3Aissue+memory)
- [OpenCode Documentation - MCP Servers](https://opencode.ai/docs/mcp-servers)
- [Railway Documentation](https://docs.railway.app/)

## 📝 版本历史

### v4.1 (当前版本) - 修复更新
- 🐛 **修复 SSE 端点** - 使用 `/global/event` 替代 `/event`，正确接收全局事件
- 🐛 **修复 PID 匹配** - 使用 `pgrep -f "/\.opencode web"` 匹配实际工作进程（PID 18）而非 wrapper（PID 9）
- ✨ 保持 v4.0 的所有功能

### v4.0 - 重大更新
- ✨ **SSE事件流监控** - 实时检测活动（无延迟）
- ✨ **混合架构** - SSE + 轮询双重保障
- ✨ **无会话限制** - 检测所有100+会话
- ✨ **更可靠的空闲检测** - 不遗漏活跃会话
- ✨ 移除 `set -e` 防止脚本意外退出

### v3.2
- ✨ 每分钟检查一次（可配置）
- ✨ 详细记录活跃 Session 信息（ID、时间、标题、目录）
- ✨ 优化日志输出频率

### v3.1
- ✨ 去掉线程数检测（MCP 干扰）
- ✨ 查询所有 Session（不只是最新的）
- ✨ 增加冷却期保护

### v3.0
- ✨ 初始版本
- ✨ 支持内存和空闲双重检测
- ✨ Railway 环境适配

## 🤝 贡献

欢迎提交 Issue 和 PR！

## 📄 许可证

MIT License - 详见 LICENSE 文件

## 📝 作者

由 opencode 自动生成并优化