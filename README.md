# ACXC-Sing-Box

基于 [sing-box](https://sing-box.sagernet.org/) 的一键协议管理脚本（开发中，自用测试）。

## 功能

- 一键安装 / 更新 / 卸载 sing-box：版本锁定，升级前先用新二进制校验现有配置，不通过就不升
- 九个协议：VLESS+Reality、Hysteria2、Shadowsocks 2022、Trojan+TLS、AnyTLS、SOCKS5、WireGuard、TUIC v5、Snell（v4/v5/v6）
- **同一协议可开多个节点**：独立端口、独立凭据、独立备注，客户端里名字可区分
- 分享链接 / 终端二维码 / links.txt
- 改端口热重载不断线；每次改动先拍快照，校验失败自动回滚
- Hysteria2 端口跳跃（nftables）
- 脚本自更新（URL 通道 + 本地文件通道）

## 用法

上传到服务器后：

```bash
bash acxc-singbox.sh      # 首次运行可装成 sb 命令，之后直接输入 sb
```

## 状态

v0.2.0 · 未发布，仅自用测试