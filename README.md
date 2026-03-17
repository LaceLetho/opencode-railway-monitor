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

### 1. Session 活跃状态检测

查询所有 Session（不是只看最新的一个）：
```bash
curl http://127.0.0.1:18080/session
```

检查每个 Session 的 `updated` 时间戳：
```bash
curl http://127.0.0.1:18080/session/{session_id}
```

**判定逻辑**：
- 🔴 活跃：任意 Session 在 15 秒内有更新
- 🟢 空闲：所有 Session 都超过 10 分钟未更新

### 2. 大模型生成状态检测

避免在 AI 生成内容时重启：

| 检测方法 | 原理 | 阈值 |
|---------|------|------|
| **Session 更新时间** | API `/session/{id}` 的 `updated` 字段 | < 15 秒 |
| **上下文切换速率** | `/proc/[pid]/status` 的 `voluntary_ctxt_switches` | > 100 次/周期 |
| **CPU 使用率** | `ps -o %cpu` | > 25% |
| **冷却期保护** | 生成后等待时间 | 60 秒 |

**注意**：不检测线程数，因为 MCP 进程可能一直开着线程。

### 3. 空闲判定标准

**系统空闲（必须同时满足）**：
- ✅ 所有 Session 都超过 IDLE_TIME_MINUTES（默认 10 分钟）未更新
- ✅ 没有在生成内容（CPU < 25%，无上下文切换激增）
- ✅ 不在冷却期（上次生成后 60 秒）

**重启条件（满足任一）**：
- 🔄 所有 Session 空闲达到 IDLE_TIME_MINUTES
- 🔄 内存使用超过 MEMORY_THRESHOLD_MB（默认 2000MB）

## 📁 文件说明

```
.
├── opencode_monitor_v3_1.sh       # ⭐ 智能监测主脚本（推荐）
├── opencode_generation_monitor_v2.sh  # 生成状态检测工具
├── README.md                        # 本文档
└── LICENSE                          # MIT 许可证
```

### 主脚本：opencode_monitor_v3_1.sh

**功能**：
- 每 30 秒检查一次所有 Session 状态
- 检测大模型是否正在生成内容
- 内存超过阈值或空闲超时时自动重启
- 优雅关闭 → 清理进程 → Railway 重新部署

**配置参数**：
```bash
IDLE_TIME_MINUTES=10          # Session 空闲时间阈值（分钟）
CHECK_INTERVAL_SECONDS=30     # 检查间隔（秒）
MEMORY_THRESHOLD_MB=2000      # 内存上限（MB）
CPU_THRESHOLD_PERCENT=5.0     # CPU 空闲阈值（%）
GENERATION_GRACE_SECONDS=60   # 生成后冷却期（秒）
```

### 辅助脚本：opencode_generation_monitor_v2.sh

**功能**：
- 实时监测大模型生成状态
- 显示所有 Session 的活动情况
- 调试和观察使用

## 🚀 使用方法

### 1. 克隆仓库

```bash
git clone https://github.com/LaceLetho/opencode-railway-monitor.git
cd opencode-railway-monitor
```

### 2. 启动监测（推荐后台运行）

```bash
# 方式 1：后台运行（推荐）
nohup ./opencode_monitor_v3_1.sh > /tmp/opencode_monitor.log 2>&1 &
echo $! > ~/.opencode_monitor.pid

# 方式 2：前台运行（调试用）
./opencode_monitor_v3_1.sh

# 方式 3：自定义参数
IDLE_TIME_MINUTES=15 MEMORY_THRESHOLD_MB=1500 ./opencode_monitor_v3_1.sh
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
pkill -f opencode_monitor_v3_1
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
ExecStart=/path/to/opencode-railway-monitor/opencode_monitor_v3_1.sh
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
[2026-03-17 07:04:32] 🚀 监测服务启动 v3.1
[2026-03-17 07:04:35] ⏱️ 0h | 内存:1208MB
[2026-03-17 07:04:35]   Session统计: 总共100个, 活跃1个
[2026-03-17 07:04:35]   📝 生成中: session更新(YjEL4Wg5ULGq, 40s) 
[2026-03-17 07:05:05] ⏱️ 0h | 内存:1208MB
[2026-03-17 07:05:05]   Session统计: 总共100个, 活跃0个
[2026-03-17 07:05:05]   🟢 全部空闲 (0/10 分钟)
...
[2026-03-17 07:14:35] 💤 所有 Session 空闲 10 分钟，执行重启
[2026-03-17 07:14:35] ========================================
[2026-03-17 07:14:35] 🔄 重启 OpenCode
[2026-03-17 07:14:35]   原因: 空闲超时
[2026-03-17 07:14:35]   重启前内存: 1208MB
[2026-03-17 07:14:40]   优雅关闭...
[2026-03-17 07:14:45]   触发重新部署...
```

## ⚙️ 配置选项

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `IDLE_TIME_MINUTES` | 10 | Session 空闲时间阈值（分钟） |
| `CHECK_INTERVAL_SECONDS` | 30 | 检查间隔（秒） |
| `MEMORY_THRESHOLD_MB` | 2000 | 内存上限（MB） |
| `CPU_THRESHOLD_PERCENT` | 5.0 | CPU 空闲阈值（%） |
| `GENERATION_GRACE_SECONDS` | 60 | 生成后冷却期（秒） |

### 调整示例

```bash
# 更激进的策略（5分钟空闲就重启，内存限制1GB）
IDLE_TIME_MINUTES=5 MEMORY_THRESHOLD_MB=1000 ./opencode_monitor_v3_1.sh

# 更保守的策略（20分钟空闲，内存限制3GB，90秒冷却期）
IDLE_TIME_MINUTES=20 MEMORY_THRESHOLD_MB=3000 GENERATION_GRACE_SECONDS=90 ./opencode_monitor_v3_1.sh
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
chmod +x opencode_monitor_v3_1.sh

# 检查依赖
which curl bc

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

## 🤝 贡献

欢迎提交 Issue 和 PR！

## 📄 许可证

MIT License - 详见 LICENSE 文件

## 📝 作者

由 opencode 自动生成并优化