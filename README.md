# WorkBuddy2API

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Go](https://img.shields.io/badge/Go-1.23+-00ADD8.svg)](https://go.dev/)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue?logo=docker)](docker-compose.yml)
[![fnOS](https://img.shields.io/badge/fnOS-FPK-orange)](releases)
[![Release](https://img.shields.io/github/v/release/Lwn666/workbuddy2api?logo=github)](https://github.com/Lwn666/workbuddy2api/releases)

> OpenAI 兼容的 WorkBuddy (CodeBuddy / copilot.tencent.com) 反向代理网关

本项目基于 [Sliverkiss/workbuddy2api](https://github.com/Sliverkiss/workbuddy2api) 二次开发，新增内置 Web 前端控制台、扫码登录、Docker 部署、fnOS 应用打包与**上游全自动同步 CI**。

## 功能特性

- **OpenAI 兼容接口** — `/v1/chat/completions`（流式/非流式）、`/v1/models`、`/status`、`/healthz`
- **内置 Web 控制台** — 账号总览、一键签到、一键刷新（本地增强，上游无）
- **扫码登录** — 生成二维码，手机扫码完成 OAuth 登录，热加入账号池无需重启（本地增强）
- **三因子加权选号** — credits × 闲置补偿 × 成功率加权，Top-5 候选 + 防惊群
- **熔断器** — 连续失败触发熔断 + 指数退避冷却，账号自动恢复
- **会话粘性** — 同会话请求路由到同一账号（内存 + Redis 镜像，多实例共享）
- **Redis 状态镜像** — 可选 Upstash Redis，账号状态跨实例同步
- **在途租约** — 单账号并发上限，防单号过载
- **定时签到** — 每日 09:00 / 21:00 自动签到，积分耗尽次日 04:00 自动恢复
- **工具调用** — 完整支持 OpenAI tools/tool_choice，SSE 流式透传
- **Docker 部署** — 一键 `docker compose up`，healthcheck 常驻
- **fnOS 安装包** — 预编译 fpk，支持 x86_64 / aarch64

## 快速开始

### 方式一：Docker 部署（推荐）

```bash
git clone https://github.com/Lwn666/workbuddy2api.git
cd workbuddy2api
cp config.example.json config.json
# 编辑 config.json，设置 api_key
docker compose up -d --build
```

### 方式二：fnOS 应用

从 [Releases](https://github.com/Lwn666/workbuddy2api/releases) 下载对应架构的 fpk（`workbuddy2api-<版本>-x86.fpk` / `-arm.fpk`），通过 fnOS 应用中心「手动安装」。

### 方式三：源码编译

```bash
go build -o server ./cmd/server
./server -config config.json  # 默认监听 :7863
```

## 使用

启动后访问 `http://localhost:7863/`：

1. 填入 API Key（安装向导配置或页面右上角输入）
2. 点击「扫码添加账号」→ 手机扫码 → 账号自动加入
3. 使用客户端调用 API（`base_url = http://localhost:7863/v1`）

```bash
# 验证
curl http://localhost:7863/v1/models -H "Authorization: Bearer your-key"
```

## 配置

```json
{
  "listen": ":7863",
  "api_key": "your-api-key",
  "auth_dir": "./auths",
  "state_file": "./data/state.json",
  "region": "cn",
  "cooldown": { "soft_rate": "60s" },
  "schedule": { "checkin_hours": [9, 21], "keepalive_hours": [22] },
  "upstream": { "timeout_seconds": 120 },
  "upstash": { "url": "", "token": "" },
  "pool": {
    "max_in_flight": 3,
    "breaker_threshold": 3,
    "breaker_cooldown": "30m",
    "breaker_cooldown_max": "6h",
    "idle_weight_per_hour": 0.5,
    "idle_weight_max": 5.0
  },
  "session_sticky": { "enabled": true, "ttl": "30m", "gc_interval": "5m" }
}
```

完整配置参考 [`config.example.json`](config.example.json)（权威定义）。

## API 端点

| 端点 | 鉴权 | 说明 |
|---|---|---|
| `POST /v1/chat/completions` | Bearer | OpenAI 兼容聊天补全（SSE 流式透传） |
| `GET /v1/models` | Bearer | 模型列表 |
| `GET /status` | Bearer | 账号状态汇总 |
| `GET /healthz` | 无 | 健康检查 |
| `POST /api/checkin` | Bearer | 手动签到（本地增强） |
| `POST /api/login/start` | 无 | 生成登录二维码（本地增强） |
| `GET /api/login/poll` | 无 | 轮询登录结果（本地增强） |

## 账号池策略

- **状态机**：Healthy → Cooling（软/硬/熔断）→ Disabled，单计数器 + 统一复活
- **选号**：三因子加权（credits / 闲置补偿 / 成功率），Top-5 短名单截断
- **保护**：熔断器（连续失败指数退避）、在途租约（单号并发上限）、防惊群（100ms 窗口）
- **粘性**：会话绑定最终成功号，TTL 过期自动释放
- **错误处理**：402 冷却到次日 04:00，429 短冷却，401 永久禁用，网络抖动立即重试

## 项目结构

```
├── cmd/server/          # 主服务（含 LOCAL PATCH：内置前端 + 本地 API）
├── internal/
│   ├── server/          # HTTP handler + Web 前端（web/ 本地增强）
│   ├── pool/            # 账号池 + 状态机 + 熔断器 + 权重
│   ├── session/         # 会话粘性路由（内存 + Redis）
│   ├── redisstore/      # Upstash Redis 封装（Noop 降级）
│   ├── auth/            # 凭证管理
│   ├── login/           # 扫码登录（本地增强）
│   ├── scheduler/       # 定时任务
│   └── upstream/        # WorkBuddy 上游客户端
├── wb2api-fpk/          # fnOS fpk 打包工程（x86）
├── wb2api-fpk-arm/      # fnOS fpk 打包工程（arm）
├── .github/workflows/   # CI：镜像 / fpk / auto-sync
├── docker-compose.yml
└── config.example.json
```

## 工具脚本

| 脚本 | 用途 |
|---|---|
| `login.sh` | 交互式登录 |
| `credit.sh` | 积分查询 |
| `signin.sh` | 批量签到 |
| `scripts/build-fpk.sh` | 交叉编译 + 打包 fpk |
| `scripts/sync-wb2-fork.sh` | 同步上游 + 重放 LOCAL PATCH |

## 上游同步机制（fork 维护）

fork 与上游无共同祖先（上游不接受 PR），通过 `.github/workflows/auto-sync-upstream.yml` 全自动维护：

- **每 6 小时轮询**上游 master（可手动 `workflow_dispatch`）
- 整树同步上游代码 → 恢复 fork 本地文件（web/login/fpk/README 等）→ 重放 LOCAL PATCH → 编译验证
- 有变化时自动：bump fpk 版本 → push master（触发 Docker 镜像构建）→ 打 tag（触发 fpk 构建 + Release）
- **同步失败自动开 Issue**，绝不推送损坏代码

手动同步：`sh scripts/sync-wb2-fork.sh --ci`

## 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/xxx`)
3. 提交更改 (`git commit -m 'feat: add xxx'`)
4. 推送分支 (`git push origin feature/xxx`)
5. 创建 Pull Request

## 许可证

[MIT](LICENSE)

## 免责声明

本项目仅供学习和研究使用。使用者需遵守 WorkBuddy / CodeBuddy 服务条款，自行承担使用风险。
