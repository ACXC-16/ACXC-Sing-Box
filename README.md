# ACXC-Sing-Box

sing-box 一键协议脚本 · 9 种协议 · 同协议多开 · 一键出链接

```bash
curl -fsSL https://acxc-16.github.io/ACXC-Sing-Box/sb.sh | sudo bash
```

**Debian 12 / Ubuntu 22.04+ · root · 装完输入 `sb`**

## 协议

| 传输 | 协议 |
|---|---|
| TCP | VLESS+Reality、Trojan、AnyTLS、SOCKS5、Snell |
| QUIC / UDP | Hysteria2、TUIC v5、WireGuard |
| TCP + UDP | Shadowsocks 2022 |

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
**容器** 需要 systemd，PID 1 不是 systemd 跑不了。
**github.io 打不开** 用 raw：`curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/sb.sh | sudo bash`
</details>

<sub>仅供学习研究 · [MIT](LICENSE)</sub>

<sub>脚本菜单抄袭 <a href="https://github.com/cshaizhihao/OU-SB">cshaizhihao/OU-SB</a>，有问题别找我</sub>
