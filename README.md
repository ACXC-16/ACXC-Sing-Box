# ACXC-Sing-Box

sing-box 一键协议脚本 · 9 种协议 · 同协议多开 · 一键出链接

```bash
# Debian / Ubuntu
curl -fsSL https://acxc-16.github.io/ACXC-Sing-Box/sb.sh | sudo bash

# Alpine（默认不带 bash，先装上）
apk add --no-cache bash curl && curl -fsSL https://acxc-16.github.io/ACXC-Sing-Box/sb.sh | bash
```

**Debian 12 / Ubuntu 22.04+（systemd）· Alpine 3.19+（OpenRC）· root · 装完输入 `sb`**

## 🔌 支持协议

- VLESS TCP + XTLS Vision + Reality（推荐）
- Shadowsocks 2022（推荐）
- Hysteria2（UDP 端口跳跃）
- Trojan TLS
- AnyTLS（TLS）
- SOCKS5（账号密码）
- WireGuard（UDP）
- TUIC v5（QUIC）
- Snell v4/v5/v6

## 用法

```bash
sb              # 菜单
sb --help       # 全部参数
sb --self-test  # 校验配置
```

<details>
<summary>完整命令</summary>

```bash
sb --add reality --name hk01 --port 443 --sni addons.mozilla.org
sb --list / --show hk01 / --link hk01 --qr
sb --clash hk01 / --sub clash
sb --del hk01 / --set-port hk01 8443 / --hop hk01 20000-30000
sb --status / --start / --stop / --restart / --log
sb --install / --update-singbox / --update-script / --uninstall
```

协议名：`reality` `hysteria2` `shadowsocks` `trojan` `anytls` `socks` `wireguard` `tuic` `snell`
</details>

<details>
<summary>文件位置</summary>

```
/usr/local/bin/sing-box
/etc/sing-box/config.json
/etc/sing-box/conf.d/in-<节点>.json
/etc/acxc-singbox/nodes/
```
</details>

<details>
<summary>FAQ</summary>

**连不上** 查安全组；TLS 协议要在客户端跳过证书校验。
**insecure=1** 自签证书，换正式证书即可去掉。
**WireGuard / Snell 没链接** 用 `sb --clash 名字`。
**容器** Debian 系要 systemd、Alpine 要 OpenRC；PID 1 是 sh 的纯容器跑不了。
**github.io 打不开** 用 raw：`curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/sb.sh | sudo bash`
</details>

<sub>仅供学习研究 · [MIT](LICENSE)</sub>

<sub>菜单布局参考 <a href="https://github.com/cshaizhihao/OU-SB">cshaizhihao/OU-SB</a>，感谢原作者</sub>
