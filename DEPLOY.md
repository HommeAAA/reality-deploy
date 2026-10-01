# Xray + VLESS + REALITY 部署与 Shadowrocket 导入

本目录提供单用户、单 VPS 的 Xray 服务端模板，以及用于生成 Shadowrocket 节点分享链接的脚本。模板使用 VLESS + REALITY + Vision；它不保证 VPS IP 不会被 GFW 封锁。任何单 IP 都可能失效，换 IP 也不能保证之后不会被封。

## 文件

- `server-config.json`：Xray 服务端配置模板。
- `gen-keys.sh`：在 VPS 上生成 X25519 密钥、UUID 和 short ID。
- `preflight.sh`：只读检查 VPS 系统、systemd、Xray 和 443 端口占用。
- `generate_shadowrocket_link.py`：生成 Shadowrocket 可导入的 VLESS URI；可选输出二维码。
- `client-singbox.json`、`client-v2rayn.json`：分别供 sing-box 和 Xray 风格客户端参考；它们不是 Shadowrocket 节点导入文件。

## 1. 检查现有 VPS

先通过 SSH 登录自己的 VPS，将 `preflight.sh` 复制到服务器并运行：

```bash
bash preflight.sh
```

脚本只读取系统版本、PID 1、Xray 安装位置、systemd 的 Xray 启动命令和 TCP 443 监听情况，不改系统配置。确认你有权限使用 443；若端口已被占用，先查明服务用途，不要直接停止未知服务。

方案面向使用 systemd 的 Linux VPS。若不是 systemd 系统，先停止并按该发行版的服务管理方式改写部署步骤，不要照搬后续 `systemctl` 命令。

## 2. 安装 Xray 并生成参数

使用 Xray 官方安装器：

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

在 VPS 上运行密钥脚本：

```bash
bash gen-keys.sh
```

妥善保存脚本输出。Xray 版本不同，客户端公钥可能标记为 `Public key`、`PublicKey` 或 `Password (PublicKey)`；将其填入链接生成器的 `--public-key`（URI 参数 `pbk`）。`PrivateKey` 只放服务端。UUID 和 short ID 两端保持一致。不要把私钥、UUID 或完整 VLESS 链接提交到公开仓库或发到公开频道。完整链接含有可连接凭据，应按密码保管。

## 3. 安装服务端配置

把 `server-config.json` 复制到官方安装器默认读取的位置：

```bash
sudo install -d -m 755 /usr/local/etc/xray
XRAY_USER="$(sudo systemctl show xray -p User --value)"
[ -n "$XRAY_USER" ] || XRAY_USER=root
XRAY_GROUP="$(sudo systemctl show xray -p Group --value)"
[ -n "$XRAY_GROUP" ] || XRAY_GROUP="$(id -gn "$XRAY_USER")"
sudo install -o root -g "$XRAY_GROUP" -m 640 server-config.json /usr/local/etc/xray/config.json
sudoedit /usr/local/etc/xray/config.json
sudo chown root:"$XRAY_GROUP" /usr/local/etc/xray/config.json
sudo chmod 640 /usr/local/etc/xray/config.json
sudo -u "$XRAY_USER" test -r /usr/local/etc/xray/config.json
```

将 `<UUID>`、`<PRIVATE_KEY>` 和 `<SHORT_ID>` 替换为本机生成的值。模板中的目标站和 SNI 只是示例值；部署前需从 VPS 所在网络验证目标站可达，且 SNI 与目标站实际接受的 TLS 名称相符。目标站选择不能保证 IP 不被封。

验证配置并启动服务：

```bash
sudo xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl enable --now xray
sudo systemctl status xray --no-pager
sudo systemctl show xray -p ExecStart --value
sudo ss -ltnp 'sport = :443'
```

确认 `ExecStart` 指向 `/usr/local/etc/xray/config.json`，并确认 Xray 正在监听 TCP 443。根据系统配置放行主机防火墙和 VPS 服务商防火墙的 TCP 443；不要开放未使用的端口。

> Xray 官方安装器默认使用 `/usr/local/etc/xray/*.json`，并安装 systemd 服务。若 VPS 上已有定制过的 Xray 服务，先核对实际 `ExecStart`，避免覆盖现有配置。

## 4. 生成 Shadowrocket 节点链接

在可信的本地电脑上下载 `generate_shadowrocket_link.py`，不要将 VLESS 链接或二维码传到公开网站。生成 PNG 二维码需本机已安装 `qrencode`；不需要二维码时，可省略 `--qr-out` 并从剪贴板导入链接。运行：

```bash
python3 generate_shadowrocket_link.py \
  --server YOUR_VPS_IP \
  --sni www.apple.com \
  --name My-VPS \
  --qr-out shadowrocket-node.png
```

脚本会隐藏提示输入 UUID、公钥和 short ID，避免这些值出现在命令历史和进程参数中；命令行不要添加这三个凭据参数。脚本输出以 `vless://` 开头的链接，并按需生成二维码。二维码文件权限设为仅当前用户可读写。分享链接和二维码都包含 UUID，应妥善保管；它们不会包含服务器私钥。

在 Shadowrocket 中扫描二维码，或复制完整 `vless://` 链接后从剪贴板导入。确认节点字段为服务器 IP、443/TCP、VLESS、REALITY、`xtls-rprx-vision`、对应 SNI、Public Key 和 Short ID。若导入后参数不完整，先与链接逐项核对，再尝试手工添加节点。

## 5. 验收与故障检查

1. 在 Shadowrocket 中连接节点，分别通过 Wi‑Fi 和蜂窝网络测试。
2. 访问 IP 查询网站，确认出口 IP 是 VPS 地址。
3. 在 VPS 上检查 `systemctl status xray`、`journalctl -u xray` 和 TCP 443 监听状态。
4. 若无法连接，依次检查服务端配置测试结果、systemd 实际配置路径、UUID/公钥/short ID/SNI/flow 是否一致、服务商与主机防火墙，以及 VPS 到目标站的 TLS 连通性。

验收只说明测试当时的连接情况。若 VPS 公网 IP 被 GFW 或上游网络屏蔽，单 VPS 方案会中断；更换 IP 或重建节点只能尝试恢复，不能保证新 IP 不会被封。

## 官方参考

- [Xray REALITY 配置文档](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/reality.md)
- [Xray-install 官方仓库](https://github.com/XTLS/Xray-install)
- [Shadowrocket App Store 页面](https://apps.apple.com/app/shadowrocket/id932747118)
