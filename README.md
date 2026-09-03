# WorkBuddy2API

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Go](https://img.shields.io/badge/Go-1.23+-00ADD8.svg)](https://go.dev/)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue?logo=docker)](docker-compose.yml)
[![fnOS](https://img.shields.io/badge/fnOS-FPK-orange)](releases)

> OpenAI 兼容的 WorkBuddy (CodeBuddy / copilot.tencent.com) 反向代理网关

本项目基于 [Sliverkiss/workbuddy2api](https://github.com/Sliverkiss/workbuddy2api) 二次开发，新增内置 Web 前端控制台、扫码登录、Docker 部署与 fnOS 应用打包。

## 功能特性

- **OpenAI 兼容接口** — `/v1/chat/completions`（流式/非流式）、`/v1/models`、`/status`、`/healthz`
- **内置 Web 控制台** — 账号总览、一键签到、一键刷新
- **扫码登录** — 生成二维码，手机扫码完成 OAuth 登录，热加入账号池无需重启
- **多账号轮转** — 加权随机选号（credits 权重），防热点 + 防惊群
- **定时签到** — 每日 09:00 / 21:00 自动签到，积分耗尽次日 04:00 自动恢复
- **工具调用** — 完整支持 OpenAI tools/tool_choice
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

从 [Releases](https://github.com/Lwn666/workbuddy2api/releases) 下载对应架构的 fpk，通过 fnOS 应用中心「手动安装」。

### 方式三：源码编译

```bash
go build -o server ./cmd/server
./server  # 默认监听 :7863
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
  "cooldown": { "err_threshold": 5, "err_cooldown": "10m" },
  "schedule": { "checkin_hours": [9, 21] }
}
```

完整配置参考 [`config.example.json`](config.example.json)。

## API 端点

| 端点 | 鉴权 | 说明 |
|---|---|---|
| `POST /v1/chat/completions` | Bearer | OpenAI 兼容聊天补全 |
| `GET /v1/models` | Bearer | 模型列表 |
| `GET /status` | Bearer | 账号状态汇总 |
| `GET /healthz` | 无 | 健康检查 |
| `POST /api/checkin` | Bearer | 手动签到 |
| `POST /api/login/start` | 无 | 生成登录二维码 |
| `GET /api/login/poll` | 无 | 轮询登录结果 |

## 账号轮换策略

- **状态机**：Healthy → Cooling → Disabled
- **挑选**：Top-5 候选 → credits 加权随机 → 防惊群（100ms 窗口）
- **错误处理**：402 冷却到次日 04:00，429 短冷却，401 永久禁用，网络抖动立即重试

## 项目结构

```
├── cmd/
│   ├── server/        # 主服务
│   ├── login/         # OAuth 登录工具
│   └── credit/        # 积分查询
├── internal/
│   ├── server/        # HTTP handler + Web 前端
│   ├── pool/          # 账号池 + 状态机
│   ├── auth/          # 凭证管理
│   └── scheduler/     # 定时任务
├── wb2api-fpk/        # fnOS fpk 打包工程（x86）
├── wb2api-fpk-arm/    # fnOS fpk 打包工程（arm）
├── docker-compose.yml
└── config.example.json
```

## 工具脚本

| 脚本 | 用途 |
|---|---|
| `login.sh` | 交互式登录 |
| `credit.sh` | 积分查询 |
| `signin.sh` | 批量签到 |
| `scripts/sync-upstream.sh` | 同步上游更新 |

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
