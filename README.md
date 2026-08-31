# WorkBuddy2API

> WorkBuddy CN（CodeBuddy / copilot.tencent.com）的 OpenAI 兼容反向代理，支持 OAuth 登录、多账号轮转、工具调用与流式响应。

🍴 **复刻说明（Fork）**：本仓库为 [Sliverkiss/workbuddy2api](https://github.com/Sliverkiss/workbuddy2api) 的二次开发，遵循原项目 MIT 协议。相比上游新增：**内置 Web 前端控制台、一键签到、扫码登录**，并附带**上游安全同步脚本**（`scripts/sync-upstream.sh`，按文件分类覆盖 + 自动重放 LOCAL PATCH，与上游零冲突）。

## 功能特性

- 🔐 **OAuth 登录** — 通过 `/v2/plugin/auth/state` 设备授权流程获取凭证，支持 token 自动刷新
- 🖥 **内置前端** — Web 控制台：账号总览卡片（昵称/UID/积分/状态徽章/禁用原因），一键刷新
- 🎯 **一键签到** — 前端按钮触发签到轮（POST /api/checkin），等效 scheduler 09:00/21:00 自动签到
- 📱 **扫码登录** — 生成二维码，手机扫码完成 OAuth 落盘（POST /api/login/start + /api/login/poll），热加入无需重启
- 🔄 **多账号轮转** — 加权随机选号（credits 权重），防热点 + 防惊群（100ms 窗口）
- 🛠 **工具调用** — 完整支持 OpenAI tools/tool_choice，流式 `tool_calls` 按 index 合并
- 📡 **流式 + 非流式** — 上游 SSE 透传；非流式本地聚合（上游拒绝非流式请求）
- ⏰ **定时签到** — 每日 09:00 / 21:00 自动签到 + 积分查询，积分耗尽账号次日 04:00 自动恢复
- 📊 **积分监控** — `credit.sh` 一键查询全部账号剩余/总量/百分比
- 🔑 **登录工具** — `login.sh` 交互式登录，落盘即生效
- 🏗 **Docker 部署** — 一键 `docker compose up`，healthcheck 常驻
- 📈 **请求级日志** — 每个 `/v1/chat/completions` 请求打表格日志（seq/TTFB/uid/tokens/latency）
- 🏥 **健康检查** — `/healthz` 无健康账号时返回 503，可接负载均衡器
- 📉 **状态汇总** — `/status` 返回 total/healthy/cooling/disabled 计数 + 每账号完整画像

## 快速开始


### 1. 克隆 & 配置

```bash
git clone https://github.com/Lwn666/workbuddy2api.git
cd workbuddy2api
cp config.example.json config.json
# 编辑 config.json，设置 api_key
```

### 2. 添加账号

```bash
./login.sh
# 打开浏览器登录 → 按 y → 自动落盘 auths/ → 重启容器
```

> 💡 也可以直接用 Web 前端的「扫码登录」页完成，落盘后热加入账号池，**无需重启**。

### 3. 启动服务

```bash
docker compose up -d --build
```

### 4. 使用内置前端

启动后浏览器打开 `http://localhost:7863/`，填入 API Key（存 localStorage，刷新不丢）：

- **账号总览**：统计卡片（账号数 / 可用数 / 禁用数）+ 每个账号一张卡片（昵称、UID、积分、状态徽章、到期时间、禁用原因）；支持**一键刷新**与**手动签到**
- **扫码登录**：点击「生成登录二维码」→ 手机扫码完成 WorkBuddy 登录 → 自动落盘 `auths/` 并加入账号池，**无需重启**

> 前端与上游 API 完全隔离（`internal/server/web/` + `web_extra.go`），`WEB_DISABLED=1` 可关闭。

### 5. 验证

```bash
# 模型列表
curl -s http://localhost:7863/v1/models -H "Authorization: Bearer your-api-key"

# 账号状态（汇总 + 每账号详情）
curl -s http://localhost:7863/status -H "Authorization: Bearer your-api-key"

# 健康检查（无健康账号时 503）
curl -s http://localhost:7863/healthz

# 聊天补全（流式）
curl -sN http://localhost:7863/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hi"}],"stream":true}'

# 聊天补全（非流式，本地聚合）
curl -s http://localhost:7863/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## 配置说明

```json
{
  "listen": ":7863",
  "api_key": "your-api-key",
  "auth_dir": "./auths",
  "state_file": "./data/state.json",
  "region": "cn",
  "cooldown": {
    "hard_credit": "12h",
    "soft_rate": "60s",
    "err_threshold": 5,
    "err_cooldown": "10m"
  },
  "schedule": {
    "checkin_hours": [9, 21],
    "keepalive_hours": [22]
  },
  "upstream": {
    "timeout_seconds": 120
  }
}
```

**注意**：`hard_credit` 字段为历史兼容保留。实际行为由 `CooldownUntilTomorrow4AM` 接管——402 + 余额关键词时，账号冷却到**次日 04:00**（本地时区），等签到任务恢复。

## 账号轮换与冷却策略

### 状态机

```
Healthy → Cooling → (签到恢复) → Healthy
   ↓           ↑
Disabled ←────┘ (session 死亡，永久)
```

### 错误分类

| 错误类型 | 冷却策略 | 恢复方式 |
|---|---|---|
| **402 + 余额关键词** | 冷却到**次日 04:00** | 签到任务（09:00/21:00）自动恢复 |
| **429 限流** | 60s 短冷却 | 到期自动恢复 |
| **401 + session 死亡** | **永久禁用** | 人工重新登录 |
| **404 上游偶发** | 60s 短冷却（不累计错误计数） | 到期自动恢复 |
| **5xx 上游故障** | 10m 冷却（累计错误计数，阈值 5） | 到期自动恢复 |
| **网络抖动** | **不冷却**，立即换号重试 | 即时 |

### 挑选策略

1. **状态过滤**：Disabled / Cooling 不选
2. **Top-5 候选**：按 credits 降序取前 5
3. **加权随机**：按 credits 为权重抽签（credits 全 0 时均匀随机）
4. **防惊群**：跳过 100ms 内刚被选中的账号（除非只剩 1 个）

### 请求级日志

每个 `/v1/chat/completions` 请求结束后打一行表格日志到 stdout：

```
| #001 | 18:31:31 | deepseek-v4 | stream | 200 | uid=0851ce35 | TTFB=801ms | tok=60 | 23.5tok/s | total=2.6s |
```

字段说明：
- `#001`：请求序号（进程级 atomic counter）
- `TTFB`：首 token 到达时间（stream 模式）
- `tok`：输出 token 数（从上游 usage.completion_tokens 精确读取，非估算）
- `uid`：账号 UID 前 8 位

## 工具脚本

| 脚本 | 用途 |
|---|---|
| `./login.sh` | OAuth 登录，落盘 auth 文件 |
| `./credit.sh` | 积分日报（美化输出） |
| `./credit.sh -json` | 积分原始 JSON |
| `./signin.sh` | 批量签到（遍历 auths/ 下所有账号） |
| `scripts/sync-upstream.sh` | 安全同步上游更新（预览 / `--apply` 执行） |

### 上游同步

本 fork 与上游无共同祖先，直接 merge 会全冲突，故采用**按文件分类定向覆盖**：

```
sh scripts/sync-upstream.sh            # 预览：列出差异与分类
sh scripts/sync-upstream.sh --apply    # 执行：覆盖安全文件 + 自动重放 LOCAL PATCH
```

- **LOCAL_ONLY**（永不触碰）：`internal/server/web/`、`web_extra.go`、`local_api.go`、`internal/login/`、`scripts/`、`.github/`
- **AUTO_PATCH**（覆盖后自动重放）：`cmd/server/main.go`（LOCAL PATCH 锚点重放）
- **安全覆盖**：其余上游文件直接 `git checkout upstream/master --`
- 执行前先 `git remote add upstream https://github.com/Sliverkiss/workbuddy2api.git`

## API 端点

| 端点 | 鉴权 | 说明 |
|---|---|---|
| `POST /v1/chat/completions` | Bearer | OpenAI 兼容聊天补全（流式/非流式） |
| `GET /v1/models` | Bearer | 模型列表（动态拉取 + 静态兜底） |
| `GET /status` | Bearer | 账号状态汇总（total/healthy/cooling/disabled + 每账号详情） |
| `GET /healthz` | 无 | 健康检查（无健康账号时 503） |
| `POST /api/checkin` | Bearer | 手动触发签到轮（本地扩展） |
| `POST /api/login/start` | 无 | 生成扫码登录二维码（本地扩展） |
| `GET /api/login/poll` | 无 | 轮询扫码登录结果（本地扩展） |

> 本地扩展端点由 `internal/server/local_api.go` 提供，`LOGIN_DISABLED=1` 可关闭。

## 稳定性设计

- **防雪崩**：上游 4xx/5xx 轮转重试（不直接返回），404 短冷却 60s 不累计 errCount
- **错误分流**：网络层错误不累计 errCount（避免抖动连坐）；HTTP 5xx 累计 errCount 阈值 5 触发冷却
- **请求日志**：表格日志（seq/TTFB/uid/tokens/latency）便于排查慢请求
- **连接池**：`MaxIdleConnsPerHost=20` 减少 TLS 握手
- **凭证续期**：token 临近过期自动 refresh，失败禁用账号
- **状态持久化**：`data/state.json` dirty flag + 5s 周期异步落盘，进程退出前强制 flush
- **防惊群**：100ms 窗口内不重复选中同一账号（高并发时打散热点）

## 开发

### 测试

```bash
go build ./...
go test ./... -count=20  # 20 次全绿（无 flake）
go vet ./...
gofmt -l .  # 应为空
```

### 代码结构

```
cmd/
  server/     # 主服务入口
  login/      # OAuth 登录工具
  credit/     # 积分查询工具
  signin/     # 批量签到工具
internal/
  auth/       # auth 文件解析 + token 刷新
  pool/       # 账号池（状态机 + 冷却 + 持久化）
  scheduler/  # 定时签到 + 积分查询
  server/     # HTTP handler + 请求日志
  upstream/   # 上游 API 封装（chat/billing/auth）
```

## 免责声明

本项目仅供学习和研究使用。使用者需遵守 WorkBuddy / CodeBuddy 的服务条款，自行承担使用风险。作者不对任何因使用本项目产生的直接或间接损失负责。

## License

MIT
