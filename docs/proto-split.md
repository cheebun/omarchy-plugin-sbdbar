# sing-box daemon proto 拆分说明

## 背景

sing-box daemon 的 gRPC 接口定义在上游的一个文件 `started_service.proto` 里（约 800 行，1 个 service、45 个 RPC、104 个顶层 message/enum），其中混着状态、日志、出站、连接、Tailscale、USB/IP、OpenConnect、OpenVPN 等多个领域。

本项目（dashboard）只关心其中一小部分，为了便于阅读和后续按需生成代码，按领域拆成多个文件，放在 `proto/sing-box/daemon/`。

- 上游来源：`github.com/sagernet/sing-box` 的 `daemon/started_service.proto`
- 上游版本：commit `4b30a03adf8453a85199bcaa7f143ee95926ca98`（Add Taildrop support，2026-08-14）。
  - 与 `v1.14.0-beta.15`、`v1.14.0-beta.17`、`v1.14.0-rc.1` 的 proto 逐字一致。
  - 正式版 `v1.14.0`–`v1.14.3` 在此基础上只多了 commit `2a38f30125`（Add Tailscale certificate API commands）：新增 `GetTailscaleCertificate` RPC、两个 message 和一个字段。
  - 插件没有用到这些内容，协议兼容，已在 1.14.3 上实际运行验证。
- 上游原文件：`docs/upstream/started_service.proto`（逐字保留，作为拆分的输入和对照；放在 `proto/` 之外，避免和拆分后的文件同时被编译导致重复定义）

## 文件划分

| 文件 | 内容 | 插件是否使用 |
| --- | --- | --- |
| `started_service.proto` | `service StartedService`，import 下面所有文件 | 是 |
| `status.proto` | `Version`、`ServiceStatus`、`SubscribeStatusRequest`、`Status`、`StartedAt`、`DeprecatedWarnings`、`DeprecatedWarning` | 是 |
| `log.proto` | `LogLevel`、`Log`、`DefaultLogLevel` | 是 |
| `outbound.proto` | `Groups`、`Group`、`GroupItem`、`OutboundList`、`URLTestRequest`、`SelectOutboundRequest`、`SetGroupExpandRequest` | 是 |
| `clash_mode.proto` | `ClashMode`、`ClashModeStatus` | 是 |
| `connection.proto` | `SubscribeConnectionsRequest`、`ConnectionEventType`、`ConnectionEvent`、`ConnectionEvents`、`Connection`、`ProcessInfo`、`CloseConnectionRequest` | 是 |
| `diagnostics.proto` | `NetworkQualityTest*`、`STUNTest*` | 否 |
| `tailscale.proto` | 名字含 `Tailscale` 的消息（状态、Ping、出口节点、SSH） | 否 |
| `taildrop.proto` | 名字含 `Taildrop` 的消息 | 否 |
| `usb.proto` | `USB*` | 否 |
| `openconnect.proto` | `OpenConnect*` | 否 |
| `openvpn.proto` | `OpenVPN*` | 否 |
| `notification.proto` | `Notification*` | 否 |

拆分前分析过依赖：各领域之间没有交叉引用（唯一的跨消息引用 `OutboundList → GroupItem` 在同一个文件内），所以领域文件之间互不 import，只有 `started_service.proto` 汇总 import。

## 拆分规则

1. **package 和 go_package 不变**：每个文件都是 `package daemon;` 加同样的 `option go_package`。消息全名（如 `daemon.Log`）和 RPC 路径（如 `/daemon.StartedService/SubscribeLog`）与上游一致，能直接和上游 sing-box 服务端通信。
2. **定义原样搬运**：不改任何消息名、字段名、字段编号，消息文本逐字复制。
3. **service 不拆**：protobuf 不允许一个 service 跨文件，`StartedService` 整体留在 `started_service.proto`。
4. **import 路径从 `proto/` 起算**：写成 `import "sing-box/daemon/log.proto";`，编译时用 `-I proto`。
5. **生成代码**：Go 代码由 `scripts/gen_go.sh` 生成到 `agent/internal/daemonpb/` 并入库（见 `docs/grpc-agent.md`）；Python 的 `*_pb2.py` 不生成、不入库。

## 同步上游

拆分由 `scripts/split_proto.py` 机械完成（按名单和前缀把顶层定义分配到各文件），不要手改 `proto/sing-box/daemon/` 下的文件。

上游更新时：

```bash
# 1. 用新版上游文件覆盖原文件
curl -fsSL -o docs/upstream/started_service.proto \
  https://raw.githubusercontent.com/SagerNet/sing-box/<tag>/daemon/started_service.proto

# 2. 重新拆分（新增的消息若没有归属，脚本会报 unassigned，需要在脚本里补名单）
python3 -I scripts/split_proto.py docs/upstream/started_service.proto proto/sing-box/daemon

# 3. 校验（见下节），然后更新本文档里的上游版本
```

## 校验

把上游原文件和拆分后的文件分别编译成 descriptor set，比较所有顶层 message/enum/service 的定义是否完全一致：

```bash
protoc -I docs/upstream --include_imports --descriptor_set_out=/tmp/orig.pb started_service.proto
protoc -I proto --include_imports --descriptor_set_out=/tmp/split.pb proto/sing-box/daemon/*.proto
for f in orig split; do
  protoc --decode=google.protobuf.FileDescriptorSet -I /usr/include google/protobuf/descriptor.proto \
    < /tmp/$f.pb > /tmp/$f.txt
done
```

然后对比两份 `.txt` 中按名字索引的顶层块（忽略文件名和 import 差异）。首次拆分时的结果：两边各 106 个顶层定义（104 个 message/enum + `StartedService` + `google.protobuf.Empty`），无缺失、无差异。
