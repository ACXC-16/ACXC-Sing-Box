# ACXC-Sing-Box

> 基于 [sing-box](https://sing-box.sagernet.org/) 的服务端「一键协议管理」脚本。
> 一条命令装好 sing-box，之后在菜单里点几下就能开出节点，直接拿到分享链接 / 二维码 / Clash 订阅。

```
   █████   █████  ██   ██  █████ 
  ██   ██ ██       ██ ██  ██     
  ███████ ██        ███   ██     
  ██   ██ ██       ██ ██  ██     
  ██   ██  █████  ██   ██  █████ 

  ACXC-SINGBOX
  基于Sing-Box协议开发的一键搭建协议脚本
```

## 特性

- **九个协议**：VLESS+TCP+XTLS Vision+Reality、Hysteria2、Shadowsocks 2022、Trojan+TLS、AnyTLS、SOCKS5、WireGuard、TUIC v5、Snell（v4/v5/v6）
- **同一协议可开多个节点**：每个节点独立端口、独立凭据、独立备注，客户端里名字可区分
- **默认端口随机**（避开 20000-30000 端口跳跃段），也可以自己指定
- **添加即校验**：写完配置先跑 `sing-box check`，再热重载，失败自动回滚到改动前
- **改端口走热重载**：SIGHUP 触发，sing-box 进程不退出（连接会瞬时重建）
- **分享三件套**：`vless://` 等链接、终端二维码、Clash/mihomo 配置（单节点片段 + 完整订阅）
- **Hysteria2 端口跳跃**：nftables 把一段 UDP 重定向到实际端口，客户端链接带 `mport`
- **脚本自更新**：菜单里一键 `git pull` + 自替换，失败保留旧版本
- **内置自检**：`sb --self-test` 用临时目录把九种协议各渲染一份，交给真实 sing-box 校验，不碰现有节点

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12 / Ubuntu 22.04+（其它 systemd 发行版可试，未测试） |
| 权限 | root |
| 架构 | x86_64 / arm64 / armv7 / armv6 / i386 |
| 依赖 | `curl` `jq` `openssl`（缺了脚本会问你要不要装） |
| 网络 | 需要能访问 GitHub（下载 sing-box 二进制） |

> 容器（PID 1 不是 systemd）里跑不了服务管理部分，会卡在「启动失败」。

## 快速开始

```bash
# 先下载再执行（推荐，看得见脚本内容）
curl -fsSLO https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/acxc-singbox.sh
sudo bash acxc-singbox.sh
```

或者直接管道执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ACXC-16/ACXC-Sing-Box/main/acxc-singbox.sh | sudo bash
```

首次运行会依次问你两件事：

1. 要不要把自己装成 `sb` 命令（之后直接输 `sb` 就能打开）
2. 要不要现在安装 sing-box（默认 v1.14.3）

## 菜单

```
 1) 查看节点配置        2) 添加协议          3) 删除协议
 4) 修改协议端口        5) HY2 端口跳跃      6) 服务器信息
 7) 启动服务            8) 停止服务          9) 重启服务
10) 查看运行日志       11) 更新 sing-box    12) 更新脚本
13) 卸载               0) 退出
```

- 二级界面里**直接回车**返回上级菜单
- 查看节点支持多个编号，例如 `选择: 1 2 3`

## 支持的协议

| 协议 | 传输 | 认证 | 分享链接 | 说明 |
|---|---|---|---|---|
| VLESS + Reality | TCP | UUID | ✅ `vless://` | 无需域名/证书，推荐 |
| Hysteria2 | QUIC/UDP | 密码 | ✅ `hysteria2://` | 抗丢包，支持端口跳跃 |
| Shadowsocks 2022 | TCP+UDP | 预共享密钥 | ✅ `ss://` | 兼容性最好，推荐 |
| Trojan + TLS | TCP | 密码 | ✅ `trojan://` | 需要伪装域名 |
| AnyTLS | TCP+TLS | 密码 | ✅ `anytls://` | 抗探测 |
| SOCKS5 | TCP | 账号密码 | ✅ `socks5://` | **明文代理**，仅建议内网/跳板用 |
| WireGuard | UDP | 密钥对 | ❌ 无标准链接 | 用 Clash 配置，客户端手动导入 |
| TUIC v5 | QUIC/UDP | UUID + 密码 | ✅ `tuic://` | 需要支持 TUIC 的客户端 |
| Snell | TCP | PSK | ❌ 无标准链接 | 用 Clash 配置；v4/v5 与 v6 二选一 |

TLS 类协议默认生成**自签证书**，链接里带 `insecure=1`（客户端需要允许跳过证书校验）。
Reality 的伪装目标默认 `addons.mozilla.org`（已实测支持 TLS 1.3 + HTTP/2），可自行更换。

## 命令行

脚本同时提供完整 CLI，适合放进别的脚本里自动化：

```bash
sb                          # 交互菜单
sb --add reality --name hk01 --port 443 --sni addons.mozilla.org
sb --add hysteria2 --port 8443
sb --list                   # 节点列表
sb --show hk01              # 节点详情 + 分享链接
sb --link hk01              # 只要链接
sb --link hk01 --qr         # 链接 + 终端二维码
sb --clash hk01             # 这一个节点的 Clash 配置
sb --sub clash              # 全部节点的 Clash 订阅（/etc/acxc-singbox/sub/clash.yaml）
sb --del hk01               # 删除
sb --set-port hk01 8443     # 改端口
sb --hop hk01 20000-30000   # HY2 端口跳跃
sb --status | --start | --stop | --restart | --log
sb --install | --update-singbox | --update-script | --uninstall
sb --self-test              # 校验九种协议配置
sb --where                  # 排查「改了没生效」：运行/仓库/安装位三个版本
```

通用选项：`-y/--yes` 无人值守、`--dry-run` 演练、`--no-color`。

## 文件都在哪

```
/usr/local/bin/sing-box                 # 二进制（版本锁定）
/usr/local/share/acxc-singbox/          # 脚本本体（sb 命令指向这里）
/etc/sing-box/config.json               # 基座配置：log / outbounds
/etc/sing-box/conf.d/in-<节点>.json     # 一个节点一个文件，sing-box -C 目录合并
/etc/sing-box/certs/                    # 自签证书
/etc/sing-box/porthop.nft               # 端口跳跃规则
/etc/acxc-singbox/nodes/<节点>.json     # 节点真相（参数 + 密钥 + 备注）
/etc/acxc-singbox/sub/                  # 导出的订阅文件
/var/log/sing-box.log                   # sing-box 日志（自动 logrotate）
/var/log/acxc-singbox.log               # 脚本操作日志
```

**节点状态和渲染产物是分开的**：`nodes/` 是唯一真相，`conf.d/` 是渲染结果。删掉 `conf.d` 里的文件不会丢数据，重新渲染即可；把 `nodes/` 打包拷走能在新机器还原全部节点。

## 为什么改配置不容易炸

每次改动都走同一条流水线：

```
快照 → 写 state → 渲染 → sing-box check → 热重载(SIGHUP) → 验证服务/端口 → 失败则整组回滚
```

sing-box 收到 SIGHUP 会自己先校验一遍配置，不合法就继续跑旧实例；脚本外面再兜一层文件级回滚。

## 常见问题

**客户端连不上？**
先看端口有没有监听：`ss -tulnp | grep 端口`；再确认云厂商**安全组**是否放行（脚本只能改本机防火墙）。TLS 类协议记得在客户端打开「跳过证书校验」。

**为什么链接里是 `insecure=1`？**
因为用的是自签证书。换成域名 + 正式证书后，把 SNI 改成你的域名，并去掉客户端的不安全选项即可。

**Reality 的 SNI 是什么？**
伪装目标，必须是不在你自己服务器上、支持 TLS 1.3 + HTTP/2 的站点。默认 `addons.mozilla.org`，各国机房可自行更换。填完整 URL 也可以，脚本会自动取出主机名。

**WireGuard / Snell 为什么没有链接？**
这两个协议没有统一的分享 URL 格式。用 `sb --clash 名字` 拿 Clash 配置，或在详情页看参数手动填。

**容器里能跑吗？**
不能。脚本依赖 systemd（`systemctl`、服务热重载）。如果 PID 1 不是 systemd，装完起不来。

**怎么彻底卸载？**
菜单 `13) 卸载`，或 `sb --uninstall`；加 `--purge` 连节点数据一起删。

## 免责声明

本项目仅供学习与技术研究使用。请遵守你所在国家/地区的法律法规，以及你所使用服务器的服务商条款。
作者不对任何因使用本脚本产生的直接或间接后果负责。

## 许可

[MIT](LICENSE)
