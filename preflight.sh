#!/usr/bin/env bash
# Read-only inventory for a Linux VPS before installing Xray.
set -u

echo "== OS =="
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  printf 'ID=%s VERSION_ID=%s PRETTY_NAME=%s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" "${PRETTY_NAME:-unknown}"
else
  echo "/etc/os-release not found"
fi

echo
echo "== Init / systemd =="
if command -v ps >/dev/null 2>&1; then
  printf 'PID 1: '
  ps -p 1 -o comm= 2>/dev/null || true
fi
if command -v systemctl >/dev/null 2>&1; then
  echo "systemctl: available"
  if systemctl cat xray >/dev/null 2>&1; then
    echo "Xray service ExecStart:"
    systemctl show xray -p ExecStart --value 2>/dev/null || true
    printf 'Xray service user/group: '
    systemctl show xray -p User -p Group --value 2>/dev/null | tr '\n' ' '
    echo
    echo "Xray service state:"
    systemctl is-active xray 2>/dev/null || true
  else
    echo "Xray systemd service: not installed"
  fi
else
  echo "systemctl: unavailable"
fi

echo
echo "== Xray binary =="
if command -v xray >/dev/null 2>&1; then
  command -v xray
  xray version 2>&1 | head -n 2
else
  echo "xray: not found in PATH"
  if [[ -x /usr/local/bin/xray ]]; then
    /usr/local/bin/xray version 2>&1 | head -n 2
  fi
fi

echo
echo "== TCP 443 listener =="
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 'sport = :443' 2>&1 || true
else
  echo "ss: unavailable; install iproute2 or check port 443 through another method"
fi

echo
echo "Read-only check complete. No files, services, firewall rules, or packages were changed."
