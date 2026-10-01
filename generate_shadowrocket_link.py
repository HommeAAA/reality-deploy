#!/usr/bin/env python3
"""Generate a VLESS + REALITY URI for import into Shadowrocket."""

from __future__ import annotations

import argparse
import getpass
import ipaddress
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from urllib.parse import quote, urlencode


def normalize_server(value: str) -> str:
    value = value.strip()
    if not value:
        raise argparse.ArgumentTypeError("server must not be empty")
    try:
        address = ipaddress.ip_address(value.strip("[]"))
    except ValueError:
        if any(ch in value for ch in "/?#@ \t\r\n"):
            raise argparse.ArgumentTypeError("server must be an IP address or hostname")
        if ":" in value:
            raise argparse.ArgumentTypeError("IPv6 addresses must be valid and will be bracketed automatically")
        return value
    return f"[{address.compressed}]" if address.version == 6 else address.compressed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a Shadowrocket-importable VLESS + REALITY URI."
    )
    parser.add_argument("--server", required=True, type=normalize_server, help="VPS IP or hostname")
    parser.add_argument("--port", type=int, default=443, help="VLESS TCP port (default: 443)")
    parser.add_argument("--uuid", help="VLESS user UUID; prompted privately if omitted")
    parser.add_argument("--public-key", help="REALITY client public key (pbk); prompted if omitted")
    parser.add_argument("--short-id", help="REALITY short ID; prompted if omitted, empty is allowed")
    parser.add_argument("--sni", required=True, help="TLS server name accepted by the server")
    parser.add_argument("--name", default="My-VPS", help="Node label (default: My-VPS)")
    parser.add_argument("--qr-out", type=Path, help="Optional PNG output path; requires qrencode")
    args = parser.parse_args()

    if args.uuid is None:
        args.uuid = getpass.getpass("VLESS UUID (input hidden): ").strip()
    if args.public_key is None:
        args.public_key = getpass.getpass("REALITY public key / pbk (input hidden): ").strip()
    if args.short_id is None:
        args.short_id = getpass.getpass("REALITY short ID (input hidden; blank allowed): ").strip()

    try:
        args.uuid = str(uuid.UUID(args.uuid))
    except ValueError as exc:
        parser.error(f"invalid UUID: {exc}")
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if not args.public_key or any(ch.isspace() for ch in args.public_key):
        parser.error("public-key must be non-empty and contain no whitespace")
    if len(args.short_id) > 16 or len(args.short_id) % 2 or not re.fullmatch(r"[0-9a-fA-F]*", args.short_id):
        parser.error("short-id must be empty or an even-length hexadecimal string of at most 16 characters")
    if not args.sni or any(ch.isspace() for ch in args.sni) or any(ch in args.sni for ch in "/?#@"):
        parser.error("sni must be a hostname without whitespace or URL delimiters")
    if not args.name:
        parser.error("name must not be empty")
    return args


def make_uri(args: argparse.Namespace) -> str:
    parameters = [
        ("encryption", "none"),
        ("flow", "xtls-rprx-vision"),
        ("security", "reality"),
        ("sni", args.sni),
        ("fp", "chrome"),
        ("pbk", args.public_key),
        ("sid", args.short_id),
        ("type", "tcp"),
    ]
    query = urlencode(parameters, quote_via=quote, safe="")
    return f"vless://{args.uuid}@{args.server}:{args.port}?{query}#{quote(args.name, safe='')}"


def write_qr(uri: str, output: Path) -> None:
    executable = shutil.which("qrencode")
    if executable is None:
        raise RuntimeError("qrencode is required for --qr-out; install it or omit --qr-out to use the URI")
    output = output.expanduser()
    if output.exists():
        raise RuntimeError(f"refusing to overwrite existing file: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [executable, "-t", "PNG", "-o", str(output), uri],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "qrencode failed")
    os.chmod(output, 0o600)


def main() -> int:
    args = parse_args()
    uri = make_uri(args)
    print(uri)
    if args.qr_out:
        try:
            write_qr(uri, args.qr_out)
        except (OSError, RuntimeError) as exc:
            print(f"QR generation failed: {exc}", file=sys.stderr)
            return 1
        print(f"QR saved with mode 0600: {args.qr_out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
