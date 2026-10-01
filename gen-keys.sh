#!/usr/bin/env bash
# 在已安装 xray 的机器上运行，生成 REALITY 所需的私钥/公钥与 UUID
# 用法: bash gen-keys.sh
set -euo pipefail

if ! command -v xray >/dev/null 2>&1; then
  echo "未检测到 xray，请先安装 Xray-core 再运行此脚本。" >&2
  exit 1
fi

echo "=== X25519 密钥对（PrivateKey 只保留在服务端；PublicKey/Password 用作客户端 pbk）==="
xray x25519

echo
echo "=== UUID（客户端与服务端共用同一个）==="
xray uuid

echo
echo "=== Short ID（服务端与客户端共用同一个）==="
od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
echo
