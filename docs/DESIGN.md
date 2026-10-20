# 设计说明

这份文档解释脚本为什么这样组织。改代码前先看一遍，能避开大部分坑。

## 一、核心概念：节点

一个**节点**= 一个协议实例 = 独立端口 + 独立凭据 + 独立备注名。

```
节点 ACXC-SB-Reality   →  端口 41923，UUID 9b2f…，备注 ACXC-SB-Reality
节点 ACXC-SB-Reality-2 →  端口 50278，UUID 4c7a…，备注 ACXC-SB-Reality-2
```

同一协议可以开任意多个，互不影响。删除其中一个不会动到其它节点。

命名规则：`ACXC-SB-<协议缩写>`，重名自动追加 `-2`、`-3`。
名字只允许 `A-Za-z0-9-`，因为它同时是文件名和 sing-box 的 `tag`。

## 二、两层存储

```
/etc/acxc-singbox/nodes/<名字>.json      ← 唯一真相（参数 + 密钥 + 备注）
        │  渲染
        ▼
/etc/sing-box/conf.d/in-<名字>.json      ← 产物，sing-box 实际读取的 config 片段
```

- **真相在 `nodes/`**：里面有备注、公钥、证书路径等 sing-box 不认识的字段
- **`conf.d/` 是产物**：只放 sing-box 认识的字段，删了可以重新渲染
- 整个 `nodes/` 打包拷走，换台机器就能还原全部节点（端口、密钥都不变）

为什么不用一份大 `config.json`：sing-box 1.14 支持 `-C <目录>`，把目录下所有 `*.json` 按文件名排序**深合并**（对象按键合并、数组追加）。所以「一个节点一个文件」天然幂等——加节点是写文件，删节点是删文件，不用重写整份配置，一个文件坏了也不连累其它节点。

> 合并行为见 `cmd/sing-box/cmd_run.go` 与 `badjson.MergeJSON`；`sing-box check` 用的是同一套读取逻辑，所以校验结果和实际运行一致。

## 三、apply 流水线

所有改动（加节点、删节点、改端口、改跳跃）都走同一个函数 `sbx_apply`：

```
1. 快照        nodes/ + conf.d/ 复制到 .snap.<pid>
2. 渲染        按 nodes/ 重建全部 conf.d/in-*.json，并清理孤儿文件
3. 校验        sing-box check -c config.json -C conf.d
4. 热重载      systemctl reload（SIGHUP）
5. 验活        服务 is-active + 端口在监听（ss）
6. 失败回滚    还原快照 → 重新渲染 → 再 check → 再 reload
```

两个安全网：

- sing-box 收到 SIGHUP 会**先自己 check**，不合法就只打日志、继续跑旧实例
- 脚本外面再兜一层文件级回滚，保证「失败等于没改」

快照必须在**写 state 之前**拍，否则回滚会把新节点一起恢复回来（这个 bug 修过一次）。

## 四、协议接入方式

每个协议要提供四件套，其余逻辑（菜单、CLI、列表、订阅、卸载）自动复用：

| 函数 | 作用 |
|---|---|
| `sbx_add_<proto>` | 生成凭据、写 state 文件 |
| `sbx_render_<proto>` | state → conf.d 里的 JSON 片段 |
| `sbx_link_node` 里的分支 | 生成分享链接（没有标准链接的返回 1） |
| `sbx_clash_proxy` 里的分支 | 生成 Clash/mihomo 的 proxies 条目 |

另外要在三个小表里登记：`sbx_proto_label`（显示名）、`sbx_proto_short`（默认名字）、`sbx_proto_net`（tcp/udp，决定端口冲突检测和验活方式）。

加完记得在 `sbx_self_test` 里补一份临时配置，`sb --self-test` 会拿真实 sing-box 校验。

## 五、性能上的约定

state 文件是我们自己用固定格式写的（两空格缩进、一键一行），所以**不要用 jq 读单个字段**——每次都是一次进程创建，一屏几十次就明显卡。

- 读字段用 `sbx_node_get`（纯 bash 解析，带 jq 兜底）
- 一屏要读很多字段时先 `sbx_node_load`，之后从 `SBX_NV` 缓存里取
- **写操作之后必须 `sbx_node_cache_drop`**，否则同进程内会读到旧值

## 六、命令与函数命名

- 全局变量一律 `SBX_` 前缀，函数一律 `sbx_` 前缀
- 函数内只 `return` 不 `exit`，方便将来被其它脚本 `source`
- 入口守卫：被 source 时（`ACXC_SBX_EMBEDDED=1`）不自动执行 `sbx_main`

## 七、目录速查

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/sing-box` | 二进制 |
| `/etc/sing-box/config.json` | 基座：log / outbounds |
| `/etc/sing-box/conf.d/` | 每节点一个 JSON 片段 |
| `/etc/sing-box/certs/` | 自签证书 |
| `/etc/sing-box/porthop.nft` | 端口跳跃规则 |
| `/etc/acxc-singbox/nodes/` | 节点真相 |
| `/etc/acxc-singbox/sub/` | 订阅导出 |
