# reality-deploy

单台 Linux VPS 上的 **Xray（VLESS + REALITY + Vision）** 一键部署模板。本项目提供配置文件、密钥生成脚本，以及一条命令即可完成部署的 `deploy.sh`。

> ⚠️ 本模板不保证 VPS 公网 IP 不会被网络管控方封锁；单 IP 方案失效时只能通过换 IP 等方 式尝试恢复，且无法保证新 IP 不被封。请自行评估合规与风险。

## 目录结构

| 文件 | 作用 |
| --- | --- |
| `deploy.sh` | **一键部署脚本**：环境检查 → 安装 Xray → 生成密钥与配置 → 启动服务 → 状态校验 |
| `server-config.json` | Xray 服务端配置模板（含占位符，由 `deploy.sh` 填充真实值） |
| `gen-keys.sh` | 单独生成 X25519 密钥 / UUID / short ID（需已安装 xray） |
| `preflight.sh` | 只读前置检查（系统、systemd、443 端口、xray 安装情况），不改系统 |
| `generate_shadowrocket_link.py` | 生成 Shadowrocket 可导入的 `vless://` 链接，可选输出二维码 |
| `client-singbox.json` / `client-v2rayn.json` | sing-box / v2rayN 客户端参考配置 |
| `DEPLOY.md` | 完整手工部署与验收说明 |

## 快速开始（一键部署）

在**目标 VPS（systemd Linux，root）**上执行：

```bash
# 方式一：克隆后运行
git clone <your-repo-url> reality-deploy && cd reality-deploy
sudo bash deploy.sh

# 方式二：下载 deploy.sh 与 server-config.json 后运行
sudo bash deploy.sh --sni www.apple.com --server <你的VPS_IP> --generate-link
```

脚本会自动完成六个阶段，并在最后打印客户端导入所需的 **UUID / public key / short ID / SNI**。
这些是可连接凭据，请按密码保管，不要提交到公开仓库或转发。

### 常用参数

| 参数 | 环境变量 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--sni <host>` | `REALITY_SNI` | `www.apple.com` | TLS Server Name |
| `--dest <host:port>` | `REALITY_DEST` | `<sni>:443` | REALITY 目标站 |
| `--server-names <列表>` | `REALITY_SERVER_NAMES` | 同 `--sni` | 逗号分隔的 serverNames |
| `--port <端口>` | `XRAY_PORT` | `443` | 监听端口 |
| `--config <路径>` | `XRAY_CONFIG_PATH` | `/usr/local/etc/xray/config.json` | 配置写入路径 |
| `--server <IP>` | `SERVER_IP` | 自动探测 | 服务器对外地址（仅用于客户端参数） |
| `--node-name <名>` | `NODE_NAME` | `My-VPS` | 客户端节点名 |
| `--skip-install` | `SKIP_INSTALL=1` | 关 | 跳过 Xray 安装，复用已有 |
| `--force` | `FORCE=1` | 关 | 重新生成密钥并覆盖配置 |
| `--dry-run` | `DRY_RUN=1` | 关 | 仅做环境检查 |
| `--generate-link` | `GENERATE_LINK=1` | 关 | 部署后生成 Shadowrocket 链接 |
| `--qr-out <路径>` | `QR_OUT` | – | 二维码 PNG 输出（需 `qrencode`） |
| `--show` | `SHOW=1` | 关 | **仅展示**已部署的客户端 VLESS 配置与 `vless://` 链接，不改动系统 |

环境变量与命令行参数均可使用，命令行优先级更高。查看全部选项：`sudo bash deploy.sh -h`。

## 回看已部署配置（--show）

部署完成后，客户端参数（UUID / public key / short ID / SNI / 端口）会以 `0600` 权限保存在
`/usr/local/etc/xray/client-params.json`。无需重新部署，单条命令即可直接把 VLESS 客户端配置与
`vless://` 导入链接打印出来：

```bash
# 直接展示（不改动系统）
sudo bash deploy.sh --show

# 指定对外 IP / 节点名（默认自动探测公网 IP；无网络时可用 --server 指定）
sudo bash deploy.sh --show --server <你的VPS_IP> --node-name My-VPS

# 同时导出 Shadowrocket 二维码 PNG
sudo bash deploy.sh --show --qr-out /root/shadowrocket.png
```

`--show` 只读取已保存的客户端参数文件并生成展示内容，不会触碰 Xray 服务、配置或密钥，可随时反复执行。

> 若尚未部署过（即 `/usr/local/etc/xray/client-params.json` 不存在），`--show` 会给出明确提示并退出，
> 不会误改系统。请先完成一次完整部署：`sudo bash deploy.sh`。

## 验收

1. 在客户端连接节点，分别通过 Wi‑Fi 与蜂窝网络测试。
2. 访问 IP 查询站点，确认出口 IP 为 VPS 地址。
3. 服务端检查：`systemctl status xray`、`journalctl -u xray`、`ss -ltnp 'sport = :443'`。
4. 若无法连接，依次核对：配置测试、systemd 实际配置路径、UUID/公钥/short ID/SNI/flow 一致性、两端防火墙、VPS 到目标站的 TLS 连通性。

## 安全须知

- 私钥、UUID、short ID 仅存于服务端配置；不要在公开渠道泄露完整 `vless://` 链接。
- `deploy.sh` 默认将配置权限设为 `0640` 且属主为 `root`，避免被非授权用户读取。
- 生成的 Shadowrocket 二维码文件权限为 `0600`，仅当前用户可读写。

详见 [DEPLOY.md](./DEPLOY.md)。
