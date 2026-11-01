# sbdbar-agent：gRPC 后端

## 现状

`sbdbar-agent` 是插件**唯一的后端**，Python 的 `client.py` 和 Clash REST 适配器已经删除。

- 数据来源只有 sing-box daemon 的 gRPC API，即 sing-box 1.14+ 配置里 `services` 下 `type: "api"` 的服务，默认监听 `127.0.0.1:9999`。
- 没有配置这个服务的 sing-box，插件无法使用。
- QML 只启动 agent 一个程序：流式数据由常驻进程按行输出 JSON，QML 用 `SplitParser` 读取；操作和配置读写是一次性命令。

选用 Go 的原因：
- sing-box 本身是 Go 写的，proto 生成最顺手。
- 编译出来是单个静态二进制，没有运行时依赖，冷启动约 5ms。

## 目录

| 路径 | 内容 |
| --- | --- |
| `agent/main.go` | 子命令分发 |
| `agent/common.go` | 连接（h2c + Bearer 鉴权）、重连循环、JSON 行输出、父进程退出检测、格式化 |
| `agent/config.go` | `~/.config/sbdbar/config.json` 的读写，以及旧 Python 配置的迁移 |
| `agent/watch.go` | `watch`：版本、状态、分组、模式 |
| `agent/connections.go` | `connections`：把连接事件合并成快照 |
| `agent/logs.go` | `logs`：按级别过滤日志，解析 seq |
| `agent/actions.go` | 一次性操作 |
| `agent/agent_test.go` | 单元测试，以及进程内 fake gRPC server 的端到端测试 |
| `agent/internal/daemonpb/` | 由 `proto/sing-box/daemon/*.proto` 生成的代码，**提交入库**，不装 protoc 也能构建 |
| `scripts/gen_go.sh` | 重新生成上面的代码。用 `M` 选项把上游的 `go_package` 换成本仓库的包，不依赖 sing-box 模块 |
| `scripts/build_agent.sh` | 构建到 `bin/sbdbar-agent`（`bin/` 不入库） |

## 命令

daemon 地址的取值顺序：`--url` 参数，然后环境变量 `BOX_API_URL`，然后配置文件，最后默认 `http://127.0.0.1:9999`。

secret 的取值顺序：环境变量 `BOX_API_SECRET`，然后配置文件。

### 流式命令

每行输出一个 JSON，进程一直运行到被结束为止。

| 命令 | 输出的行 | 使用方 |
| --- | --- | --- |
| `watch [--interval 2s]` | `hello`、`status`、`groups`、`mode` | BarWidget，常驻运行，Panel 也读它的数据 |
| `connections [--interval 1s]` | `connections`：完整快照，按新到旧排序，最多 150 条 | Panel，只在连接页打开时运行 |
| `logs [--level info]` | `logs`：`reset: true` 表示替换整个列表，否则追加；首批最多 300 条 | Panel，只在日志页打开且未暂停时运行 |

所有流在断线时都会输出 `{"type":"offline","status":401|0|500,"error":...}`，然后按指数退避重连：1s、2s、4s……直到上限 30s；收到过数据就重置退避。

配置错误时，比如要通过明文把 secret 发给非回环地址，进程以退出码 2 结束，QML 不会再自动拉起它。

### 一次性命令

输出一个 JSON：`{"success": bool, "status"?: int, "error"?: string}`。

- `select <group> <node>`
- `urltest [group]`：不带 group 时，并发测试全部分组。
- `set-mode <mode>`：按 daemon 返回的模式列表做大小写不敏感匹配。
- `close <id>`
- `close-all`
- `get-config`
- `save-config [--url URL] [--traffic bool]`：secret 通过环境变量传入，不出现在 ps 里。
- `set-traffic <bool>`
- `set-groups-view <card|list>`：保存分组页的显示方式（卡片或列表）。

## 实测结论（sing-box 1.14.3）

- **鉴权**：metadata 里放 `authorization: Bearer <secret>`。secret 错误时返回 `invalid authorization`，缺失时返回 `missing authorization`，都映射为 401。
- **`SubscribeStatusRequest.interval` 和 `SubscribeConnectionsRequest.interval`**：单位是纳秒，即 Go 的 `time.Duration`。连上后第一条立即推送。
- **`StartedAt.startedAt`**：单位是毫秒。算出的运行时长和 sing-box 进程的 etime 一致。
- **模式名**：daemon 返回的是小写，比如 `rule`、`direct`、`global`。
- **连接事件**：
  - UPDATE 只带 `uplinkDelta` 和 `downlinkDelta`，速率要按「增量 ÷ 间隔」计算。
  - 某一批里没有收到 UPDATE 的连接，速率视为 0。
- **日志**：
  - `message` 里自带 sing-box 的 ANSI 颜色码，原样放进 `raw`，Panel 用 `ansiToHtml` 渲染。
  - 去掉颜色码和 `LEVEL[seq]` 前缀后的文本放进 `message`，用于搜索。
  - 第一批 `reset` 会回放 daemon 的整个缓冲（实测 2342 条），agent 只保留最后 300 条。
- **进程生命周期**：
  - 父进程被 SIGKILL 后，agent 在 0.5 秒内退出。机制是 `PR_SET_PDEATHSIG`，另外每 2 秒轮询一次 ppid 兜底。
  - stdout 关闭时也会退出。

## 尚未完成

1. 分发：用 GitHub Releases 发布 amd64 和 arm64 的预编译二进制，这样用户不用自己装 Go 来构建。
2. TLS 支持（`https://` 的 API 地址）。
