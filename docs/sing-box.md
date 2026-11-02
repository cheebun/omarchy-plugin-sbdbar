# sing-box 配置指南

sbdbar 只通过 sing-box 的 daemon gRPC API 通信，不使用 Clash API（`experimental.clash_api`）。本文说明 sing-box 端需要做哪些配置，以及常见问题怎么排查。

## 版本要求

- 需要 **sing-box 1.14+**。daemon API 服务是 1.14 新增的。
- 已在 sing-box 1.14.3 上实际验证。
- 插件内置的 proto 对应上游 commit `4b30a03adf`，与 `v1.14.0-rc.1` 一致。
  - 正式版 v1.14.0–v1.14.3 在此基础上只多了 Tailscale 证书接口，插件没有用到，协议兼容。
  - 详见 `docs/proto-split.md`。

## 启用 API 服务

在 sing-box 配置的 `services` 里加入 `api` 服务：

```json
{
  "services": [
    {
      "type": "api",
      "listen": "127.0.0.1",
      "listen_port": 9999,
      "secret": "your-secret-token"
    }
  ]
}
```

| 字段 | 说明 |
| --- | --- |
| `listen` | 建议只监听 `127.0.0.1`。插件目前只支持明文 h2c（`http://`），不支持 TLS。 |
| `listen_port` | 插件默认连 `9999`。如果改了端口，要在面板的 Settings 里填写对应地址，或者在 `shell.json` 里设置 `url`。 |
| `secret` | 插件以 `authorization: Bearer <secret>` 的形式发送。在面板 Settings 里填写，或者在 `shell.json` 里设置 `password`。 |

出于安全考虑，插件拒绝通过明文把 secret 发送到非回环地址。这种情况下 agent 会直接以退出码 2 退出，不会重试。

## 模式切换（Rule / Global / Direct）

面板里显示的模式列表由 sing-box 生成，规则是：**固定的 `Rule`，加上路由规则中出现过的所有 `clash_mode` 值**。

- 这个功能**不需要**开启 Clash API。
- 如果配置里没有任何 `clash_mode` 规则，模式列表里就只有 `Rule`。这时切换到 global 会报错：`mode "global" not available; add a clash_mode rule for it in the sing-box config`。

要让 Global 和 Direct 可用，在 `route.rules` 中加入对应规则。一般放在最前面，这样切换模式能立即覆盖后面的规则：

```json
{
  "route": {
    "rules": [
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "Proxies" }
    ],
    "final": "Proxies"
  }
}
```

- 模式名的大小写保持规则里写的样子。规则写 `Global`，面板就显示 `Global`。
- 面板切换模式时不区分大小写，所以点 `global` 也能匹配到 `Global`。

以上行为已经用临时的 sing-box 1.14.3 实例验证过。对比了三种配置：没有 `clash_mode` 规则、只有 `clash_mode` 规则、同时开启 Clash API。后两者的模式列表和切换结果完全一致。

## 修改配置后

先校验，再让 sing-box 重新加载：

```bash
sing-box check -c /etc/sing-box/config.json
sudo systemctl restart sing-box
```

- Arch 的 sing-box 包自带 systemd unit，里面定义了 `ExecReload`（发送 SIGHUP），所以也可以用 `sudo systemctl reload sing-box`。
- sing-box 重启期间，状态栏会短暂显示离线。agent 会按 1s、2s、4s……的间隔自动重连，最长间隔 30s，不需要重启 Omarchy shell。

sing-box 停止时，日志里通常会出现下面这条 ERROR。这是上游关闭顺序造成的，不影响新进程：

```
sing-box did not closed properly: close service: close service/api[0]: close tcp 127.0.0.1:9999: use of closed network connection
```

## 安全建议

- API 只监听 `127.0.0.1`，并且设置 `secret`。
- sing-box 配置文件里存有 secret，不要让它对所有用户可读。例如 `chmod 600 /etc/sing-box/config.json`，或者让属组只包含运行 sing-box 的用户。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 状态栏提示 `sbdbar-agent not found` | 还没构建 agent。运行 `scripts/build_agent.sh`。 |
| 状态栏离线，错误信息含 `connection refused` | sing-box 没有启用 `api` 服务，或者端口和插件配置不一致。 |
| 显示 401，错误信息为 `missing authorization` 或 `invalid authorization` | 没有填 secret，或者 secret 与 sing-box 配置不一致。 |
| 模式只有 `Rule` | 路由规则里没有 `clash_mode` 规则，见上文。 |
| 分组里没有 `GLOBAL` | `GLOBAL` 是 Clash API 为兼容 Clash 面板拼出来的只读伪分组，gRPC 不返回它。全局模式实际走的是 `route.final` 指向的出站。 |
| 节点没有 UDP 标记 | gRPC 的分组数据不包含节点是否支持 UDP，只有 Clash API 提供。 |
| "Real IP" 显示 STUN 超时（`i/o timeout`） | 当前选择的 STUN 服务器经 `direct` 连不通，可以在设置里换一个，比如默认的 MiWiFi。 |
| "Real IP" 显示 `outbound not found` | 配置里没有名为 `direct` 的出站，需要在 sing-box 配置中添加一个 `type: "direct"`、tag 为 `direct` 的出站。 |
| agent 启动后立即退出，退出码 2 | 配置错误，例如用明文连接非回环地址，或者使用了 `https://`。 |
