# E-Doh


```
apt update -y && apt install -y dnsutils curl && FILE="doh.sh" && curl -sSL -H "Accept: application/vnd.github.v3.raw" -o $FILE "https://api.github.com/repos/xtonly/E-Doh/contents/doh.sh?ref=main" && chmod +x $FILE && ./$FILE
```



# E-Doh Manager

**E-Doh** 是一款专为 Linux 服务器打造的本地加密 DNS（DoH / DoT）交互式破局与防泄漏管理工具（基于轻量级 `AdGuard dnsproxy` 内核）。

专为解决上游网络 **53 端口（UDP/TCP）被透明劫持、污染或彻底封死超时** 而设计，支持在系统完全丧失域名解析能力的极端环境下**免本地 DNS 冷启动部署**，并内置针对 Docker 容器 DNS 自动回退 `8.8.8.8` 的深度避坑机制。

---

## 核心特性 / Key Features

* **无 DNS 死锁冷启动 (Zero-DNS Bootstrap)**：内置多路纯 IP 443 加密通道（`1.1.1.1` / `8.8.8.8` / `101.101.101.101` / `94.140.14.140` / `223.5.5.5`）动态解析并直连拉取组件，即使本机 53 端口 100% 瘫痪也能一键救活。
* **黑洞节点自动预检剔除 (Dead-Node Auto-Prune)**：生成配置前自动并发探活，自动剔除被机房或上游路由黑洞的加密节点，杜绝慢节点拖累负载均衡池。
* **全球 6 大地区优选策略 (Regional Load-Balance)**：内置全球通用、台湾本土（HiNet / TWNIC）、亚太新港日（DNS.SB / IIJ / AdGuard）、欧洲纯 IP 专线（Quad9-ECS / Mullvad）、北美专线、中国大陆防限速组，支持 ECS 精准 CDN 调度与 4MB 乐观内存缓存。
* **Docker 容器防回退避坑 (Docker Bridge Guard)**：自动监听 `docker0` 网桥网关（如 `172.17.0.1:53`）、放行防火墙并无损合并 `/etc/docker/daemon.json`，彻底解决宿主机指向 `127.0.0.1` 时 Docker 强行将容器回退至 `8.8.8.8:53` 导致容器断网的大坑。
* **全盘泄漏审计与并发测速 (Speedtest & Leak Audit)**：支持本机直连全球 12 大主流 DoH 的 HTTP/2 复用延迟（Warm）与首次握手耗时（Cold）并发测速排行；一键扫描容器、代理配置硬编码明文 DNS 及实时外部 53 端口连接。
* **防御性运维与零残留卸载 (Backup x3 & Zero-Trace Purge)**：开启 `/etc/resolv.conf` 防篡改锁（`chattr +i`），自动保留最近 3 份配置归档备份；支持在线无损热更新与 100% 零残留自毁卸载。

---

## 快速安装 / Quick Start

### 1. 常规环境一键安装（GitHub 主源优先 + Cloudflare CDN 自动回退）

适用于当前 DNS 仍可解析，希望升级为加密 DoH 防劫持或优化解析速度的机器：

```bash
(curl -fsSL --connect-timeout 5 "[https://raw.githubusercontent.com/xtonly/E-Doh/refs/heads/main/doh.sh](https://raw.githubusercontent.com/xtonly/E-Doh/refs/heads/main/doh.sh)" || curl -fsSL "[https://testingcf.jsdelivr.net/gh/xtonly/E-Doh@main/doh.sh](https://testingcf.jsdelivr.net/gh/xtonly/E-Doh@main/doh.sh)") | ($( [ "$(id -u)" -eq 0 ] && echo bash || echo "sudo bash" ))
```

### 2. 故障机破局安装（53 端口被彻底封死 / 无法解析任何域名时专用）

当机器执行 `apt update` 或 `curl` 均报 `Temporary failure resolving` / `Could not resolve host` 时，直接以 `root` 运行以下免 DNS 引导命令：

```bash
IP=""; for d in 101.101.101.101 94.140.14.140 1.1.1.1 223.5.5.5; do IP=$(curl -4ks --connect-timeout 2 "https://${d}/dns-query?name=api.github.com&type=A" -H "accept: application/dns-json" | grep -oE '"data":"[0-9.]+"' | head -n1 | cut -d'"' -f4); [ -n "$IP" ] && break; done && FILE="/usr/local/bin/doh" && curl -4fsSL --resolve "api.github.com:443:${IP:-140.82.114.6}" -H "Accept: application/vnd.github.v3.raw" -o "$FILE" "[https://api.github.com/repos/xtonly/E-Doh/contents/doh.sh?ref=main](https://api.github.com/repos/xtonly/E-Doh/contents/doh.sh?ref=main)" && chmod +x "$FILE" && doh
```

> 安装完成后，随时在终端输入 **`doh`** 即可呼出双语交互式管理面板。

---

## 交互式管理面板 / TUI Menu

```text
========================================================================
   E-Doh Manager v3.1  |  本地加密 DNS 与全球分流管理面板 (cmd: doh)
========================================================================
  运行状态 Engine   : ● Active  (dnsproxy v0.86.0)
  监听端点 Listen   : 127.0.0.1,172.17.0.1:53 (TCP + UDP)
  上游策略 Upstream : TW Local (HiNet + Google + CF + AdGuard + DNS.SB)
  系统锁定 Resolv   : Locked +i (防篡改已锁)  [备份 Backups: 3/3]
  容器环境 Docker   : Protected (172.17.0.1:53)
------------------------------------------------------------------------
  [1] 安装 / 切换分地区 DoH 策略    (Install / Switch Regional DoH)
  [2] 启用系统原生 DoT 急救模式     (Enable Native DoT 853)
  [3] 修复 Docker 容器 DNS 防回退   (Fix Docker Bridge DNS)
  [4] 实测本地 DNS 解析 (IPv4/IPv6) (Test Local DNS Resolution)
  [5] 全球 12 大 DoH 并发测速排行   (Global DoH Upstream Speedtest)
  [6] 全盘扫描 53 端口漏网之鱼      (Audit Port 53 Leaks)
  [7] 查看当前实例运行日志          (View Current Instance Logs)
  [8] 解锁 / 锁定 /etc/resolv.conf  (Toggle Resolv +i Lock)
  [9] 在线无损更新脚本与内核        (Lossless Update Script & Core)
  [10] 彻底卸载并清空全部备份       (Complete Uninstall & Purge)
  [0] 退出管理面板                  (Exit)
========================================================================
```

---

## 命令行静默自动化 / Unattended CLI

支持非交互参数，方便直接集成进新机初始化脚本：

| 命令参数 | 功能说明 |
| :--- | :--- |
| `doh --auto global` | 免交互自动部署 **全球自动优选组** 并接管系统与 Docker DNS |
| `doh --auto tw` | 免交互自动部署 **台湾本土流媒体组** (HiNet / Google / CF / TWNIC) |
| `doh --auto apac` | 免交互自动部署 **亚太新港日优化组** (DNS.SB / AdGuard / IIJ) |
| `doh --auto eu` | 免交互自动部署 **欧洲纯 IP 低延迟组** (Quad9-ECS / CF / Mullvad) |
| `doh --auto na` | 免交互自动部署 **北美专线极速组** (Quad9-ECS / CF / OpenDNS / ControlD) |
| `doh --auto cn` | 免交互自动部署 **中国大陆防限速组** (AliDNS / DNSPod / 360DoH) |
| `doh --test` | 命令行直接输出本地 IPv4 / IPv6 及 Docker 网桥解析延迟报告 |
| `doh --audit` | 命令行运行全盘容器、代理后端配置与实时外部 53 端口泄漏扫描 |
| `doh --purge` | 免交互执行 **100% 零残留彻底卸载**（还原原始 DNS 并清理所有内核、日志、备份与脚本本身） |

---

## 代理后端与容器配合避坑提示 / Best Practices

1. **代理服务端内置 DNS**：若机器运行了 `Xray`、`sing-box`、`Mihomo`、`V2bX` 等组件，请检查其配置文件中是否写死了明文 `"8.8.8.8"` 或 `"1.1.1.1"`（会导致程序绕过系统 `/etc/resolv.conf` 直接外发 UDP 53 超时）。建议将其改为 `"localhost"` / `"127.0.0.1"` 以复用本机 `dnsproxy` 乐观缓存，或直接填写 `https://...` 加密上游（可通过面板 `[6]` 一键扫描定位）。
2. **存量 Docker Compose 容器**：脚本修改 `/etc/docker/daemon.json` 并重启 Docker 服务后，若早期创建的自定义网络容器内部 `/etc/resolv.conf` 注释中仍残留旧的 `ExtServers: [8.8.8.8]`，在对应项目目录执行一次 `docker compose up -d --force-recreate` 即可刷新生效。

---

## 系统兼容性 / Compatibility

* **OS**: Debian 11 / 12 (Bookworm) / 13 (Trixie), Ubuntu 20.04 / 22.04 / 24.04+, CentOS / Rocky / AlmaLinux (systemd)
* **Arch**: `x86_64 (amd64)`, `aarch64 (arm64)`, `armv7l`

## License

MIT License
