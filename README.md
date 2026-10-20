# ACXC-Sing-Box

基于 [sing-box](https://sing-box.sagernet.org/) 的 VPS 一键协议脚本：**9 种协议**、同协议多开、一键生成分享链接 / 二维码 / Clash 订阅。

```bash
curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/acxc-singbox.sh | sudo bash
```

> Debian 12 / Ubuntu 22.04+ · root 权限 · 需要能访问 GitHub
> 首次运行会装好 sing-box 并生成 `sb` 命令，之后直接输 `sb` 进菜单。

## 特性

- **9 种协议**：VLESS+Reality、Hysteria2、Shadowsocks 2022、Trojan、AnyTLS、SOCKS5、WireGuard、TUIC、Snell
- **同协议多开**：每个节点独立端口 / 凭据 / 备注，客户端里能区分
- **改不炸**：渲染 → `sing-box check` → 热重载 → 验活，任何一步失败自动回滚
- **分享三件套**：分享链接、终端二维码、Clash/mihomo 订阅
- **自带自检**：`sb --self-test` 用真实 sing-box 校验全部协议，不碰现有节点

## 协议

| 协议 | 传输 | 认证 | 链接 |
|---|---|:---:|:---:|
| VLESS + Reality | TCP | UUID | ✅ |
| Hysteria2 | QUIC/UDP | 密码 | ✅ |
| Shadowsocks 2022 | TCP+UDP | 预共享密钥 | ✅ |
| Trojan | TCP/TLS | 密码 | ✅ |
| AnyTLS | TCP/TLS | 密码 | ✅ |
| SOCKS5 | TCP | 账号密码 | ✅ |
| TUIC v5 | QUIC/UDP | UUID + 密码 | ✅ |
| WireGuard | UDP | 密钥对 | — |
| Snell v4/v5/v6 | TCP | PSK | — |

TLS 类协议默认自签证书（链接带 `insecure=1`，客户端需允许跳过校验）。
Reality 伪装目标默认 `addons.mozilla.org`，可自行更换。

## 菜单

```
 1) 查看节点配置        2) 添加协议          3) 删除协议
 4) 修改协议端口        5) HY2 端口跳跃      6) 服务器信息
 7) 启动服务            8) 停止服务          9) 重启服务
10) 查看运行日志       11) 更新 sing-box    12) 更新脚本
13) 卸载               0) 退出
```

二级界面**回车即返回**；查看节点支持多选，例如 `选择: 1 2 3`。

## 命令行

```bash
sb                                    # 交互菜单
sb --add reality --name hk01 --port 443 --sni addons.mozilla.org
sb --list                             # 节点列表
sb --show hk01                        # 详情 + 链接
sb --link hk01 --qr                   # 链接 + 二维码
sb --clash hk01                       # 单节点 Clash 配置
sb --sub clash                        # 全部节点的 Clash 订阅
sb --del hk01 / --set-port hk01 8443  # 删除 / 改端口
sb --hop hk01 20000-30000             # HY2 端口跳跃
sb --self-test                        # 校验 9 种协议配置
sb --uninstall [--purge]              # 卸载（--purge 连数据一起删）
```

通用选项：`-y/--yes` 无人值守、`--dry-run` 演练、`--no-color`。

## 文件位置

```
/usr/local/bin/sing-box               # 二进制
/etc/sing-box/config.json             # 基座配置
/etc/sing-box/conf.d/in-<节点>.json   # 每节点一个文件
/etc/acxc-singbox/nodes/              # 节点真相（参数 + 密钥）
/etc/acxc-singbox/sub/                # 导出的订阅
/var/log/sing-box.log                 # 运行日志
```

节点状态和配置产物分开存放：`nodes/` 是唯一真相，`conf.d/` 由它渲染。拷走 `nodes/` 就能在新机器还原全部节点。

## 常见问题

<details>
<summary>客户端连不上？</summary>

先确认端口在监听（`ss -tulnp | grep 端口`），再检查云厂商**安全组**是否放行（脚本只能改本机防火墙）。
TLS 类协议记得在客户端打开「跳过证书校验」。
</details>

<details>
<summary>为什么链接里有 insecure=1？</summary>

用的是自签证书。换成域名 + 正式证书后，把 SNI 改成你的域名并关掉客户端的跳过校验即可。
</details>

<details>
<summary>Reality 的 SNI 怎么选？</summary>

伪装目标必须是不在你自己服务器上、支持 TLS 1.3 + HTTP/2 的站点。默认 `addons.mozilla.org`，按机房地区换更自然的站点更好。填完整 URL 也可以，脚本会自动取出主机名。
</details>

<details>
<summary>WireGuard / Snell 为什么没有链接？</summary>

这两个协议没有统一的分享 URL。用 `sb --clash 名字` 拿 Clash 配置，或在详情页看参数手动填。
</details>

<details>
<summary>容器里能跑吗？</summary>

不能。依赖 systemd（`systemctl`、服务热重载）。PID 1 不是 systemd 时装完起不来。
</details>

<details>
<summary>设计细节</summary>

节点模型、两层存储、apply 流水线、如何新增协议，见 [docs/DESIGN.md](docs/DESIGN.md)。
</details>

## 免责声明

仅供学习与技术研究。请遵守所在地法律法规及服务器服务商条款，使用后果自负。

## 许可

[MIT](LICENSE)
