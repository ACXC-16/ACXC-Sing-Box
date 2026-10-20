# ACXC-Sing-Box

基于 [sing-box](https://sing-box.sagernet.org/) 的 VPS 一键协议脚本 —— 9 种协议、同协议多开、一键出分享链接。

```bash
curl -fsSL https://acxc-16.github.io/ACXC-Sing-Box/sb.sh | sudo bash
```

<sub>Debian 12 / Ubuntu 22.04+ · root · 需要能访问 GitHub · 首次运行会装好 sing-box 并生成 `sb` 命令</sub>

<sub>访问不了 `github.io` 时用备用地址：`curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/sb.sh | sudo bash`</sub>

## 特性

- **9 种协议**，同协议可开多个节点，端口与凭据互相独立
- **改动即校验**：渲染 → `sing-box check` → 热重载 → 验活，任何一步失败自动回滚
- **分享**：菜单直接出链接；Clash 配置 `sb --clash` / `sb --sub`，二维码 `sb --link 名字 --qr`
- **自带自检**：`sb --self-test` 用真实 sing-box 校验全部协议，不碰现有节点

## 协议

VLESS+Reality · Hysteria2 · Shadowsocks 2022 · Trojan · AnyTLS · SOCKS5 · WireGuard · TUIC v5 · Snell v4/v5/v6

TLS 类默认自签证书（链接带 `insecure=1`）；Reality 伪装目标默认 `addons.mozilla.org`。

## 快速上手

```bash
sb                 # 交互菜单（二级页面回车即返回）
sb --help          # 全部参数
sb --self-test     # 校验 9 种协议配置
```

<details>
<summary>菜单长什么样</summary>

```
 1) 查看节点配置        2) 添加协议          3) 删除协议
 4) 修改协议端口        5) HY2 端口跳跃      6) 服务器信息
 7) 启动服务            8) 停止服务          9) 重启服务
10) 查看运行日志       11) 更新 sing-box    12) 更新脚本
13) 卸载               0) 退出
```
</details>

<details>
<summary>完整命令</summary>

```bash
sb --add reality --name hk01 --port 443 --sni addons.mozilla.org
sb --add hysteria2 --port 8443      # 协议：reality / hysteria2 / shadowsocks /
                                    #      trojan / anytls / socks / wireguard / tuic / snell
sb --list                           # 节点列表
sb --show hk01                      # 详情 + 链接
sb --link hk01 --qr                 # 链接 + 二维码
sb --clash hk01                     # 单节点 Clash 配置
sb --sub clash                      # 全部节点的 Clash 订阅
sb --del hk01                       # 删除
sb --set-port hk01 8443             # 改端口（热重载）
sb --hop hk01 20000-30000           # Hysteria2 端口跳跃
sb --status | --start | --stop | --restart | --log
sb --install | --update-singbox | --update-script | --uninstall [--purge]
sb --where                          # 排查「改了没生效」
```

通用选项：`-y/--yes` 无人值守、`--dry-run` 演练、`--no-color`。
</details>

<details>
<summary>文件都在哪</summary>

```
/usr/local/bin/sing-box               # 二进制
/etc/sing-box/config.json             # 基座配置
/etc/sing-box/conf.d/in-<节点>.json   # 每节点一个文件
/etc/acxc-singbox/nodes/              # 节点真相（参数 + 密钥）
/etc/acxc-singbox/sub/                # 导出的订阅
/var/log/sing-box.log                 # 运行日志
```

节点状态和配置产物分开存放：`nodes/` 是唯一真相，`conf.d/` 由它渲染。拷走 `nodes/` 就能在新机器还原全部节点。
</details>

<details>
<summary>常见问题</summary>

**客户端连不上？** 先确认端口在监听（`ss -tulnp | grep 端口`），再检查云厂商安全组是否放行（脚本只能改本机防火墙）。TLS 类协议记得在客户端打开「跳过证书校验」。

**为什么链接里有 insecure=1？** 用的是自签证书。换成域名 + 正式证书后，把 SNI 改成你的域名并关掉客户端的跳过校验即可。

**Reality 的 SNI 怎么选？** 必须是不在你自己服务器上、支持 TLS 1.3 + HTTP/2 的站点。默认 `addons.mozilla.org`，按机房地区换更自然的站点更好；填完整 URL 也可以。

**WireGuard / Snell 为什么没有链接？** 这两个协议没有统一的分享 URL，用 `sb --clash 名字` 拿配置。

**容器里能跑吗？** 不能，依赖 systemd。PID 1 不是 systemd 时装完起不来。

**怎么彻底卸载？** 菜单 `13)` 或 `sb --uninstall`，加 `--purge` 连节点数据一起删。
</details>

<details>
<summary>想改代码</summary>

节点模型、两层存储、apply 流水线、新增协议的约定，见 [docs/DESIGN.md](docs/DESIGN.md)。
</details>

---

<sub>仅供学习与技术研究使用，请遵守所在地法律法规及服务商条款 · [MIT](LICENSE)</sub>
