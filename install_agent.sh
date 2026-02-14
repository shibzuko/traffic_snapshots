#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "❗ Запусти через sudo:"
  echo "   sudo bash $0 --endpoint <url> [--iface <iface>] [--interval <sec>]"
  exit 1
fi

ENDPOINT=""
INTERFACE=""   # optional: --iface eth0
INTERVAL="60"  # seconds

usage() {
  cat <<EOF
Usage:
  sudo bash install_agent.sh --endpoint https://example.com/api/ingest [--iface eth0] [--interval 60]

Options:
  --endpoint   Full URL to POST metrics JSON
  --iface      (Optional) Network interface to read counters from (default: total)
  --interval   (Optional) Sampling interval seconds (default: 60)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --iface) INTERFACE="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$ENDPOINT" ]]; then
  echo "❌ Нужно указать --endpoint"
  usage
  exit 1
fi

echo "=============================="
echo " Traffic Snapshots Agent setup"
echo "=============================="
echo "Endpoint: $ENDPOINT"
echo "Iface:    ${INTERFACE:-<total>}"
echo "Interval: $INTERVAL sec"
echo

echo "1) Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-psutil python3-requests ca-certificates

AGENT_DIR="/opt/traffic_snapshots_agent"
ENV_FILE="/etc/traffic_snapshots_agent.env"
SERVICE_FILE="/etc/systemd/system/traffic_snapshots_agent.service"

echo "2) Создание директории агента: $AGENT_DIR"
mkdir -p "$AGENT_DIR"

echo "3) Установка agent.py..."
cat > "$AGENT_DIR/agent.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import time
from dataclasses import dataclass
from typing import Optional, Tuple

import psutil
import requests


@dataclass(frozen=True)
class Config:
    endpoint: str
    interval_sec: int
    interface: Optional[str]


def get_env_required(name: str) -> str:
    v = os.getenv(name, "").strip()
    if not v:
        raise RuntimeError(f"Missing required env var: {name}")
    return v


def get_primary_local_ip() -> str:
    """
    Определяет IP, через который машина ходит "наружу"
    (через UDP connect без отправки пакетов).
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "0.0.0.0"
    finally:
        try:
            s.close()
        except Exception:
            pass


def get_public_ip(timeout: float = 2.5) -> Optional[str]:
    """
    Публичный IP полезен, если ноды в разных сетях/NAT.
    Если недоступен — вернём None и используем локальный.
    """
    try:
        r = requests.get("https://api.ipify.org", timeout=timeout)
        r.raise_for_status()
        ip = r.text.strip()
        if ip:
            return ip
    except Exception:
        return None
    return None


def read_net_bytes(interface: Optional[str]) -> Tuple[int, int]:
    """
    Возвращает (rx_bytes, tx_bytes).
    Если interface=None — берём суммарные counters.
    """
    if interface:
        pernic = psutil.net_io_counters(pernic=True)
        nic = pernic.get(interface)
        if nic is None:
            raise RuntimeError(
                f"Network interface '{interface}' not found. Available: {', '.join(sorted(pernic.keys()))}"
            )
        return nic.bytes_recv, nic.bytes_sent
    c = psutil.net_io_counters(pernic=False)
    return c.bytes_recv, c.bytes_sent


def bytes_per_sec_to_bps(delta_bytes: int, delta_sec: float) -> int:
    if delta_sec <= 0:
        return 0
    # bytes/sec -> bits/sec
    bps = int((delta_bytes * 8) / delta_sec)
    return max(bps, 0)


def post_json(endpoint: str, payload: dict) -> None:
    # keepalive session
    with requests.Session() as s:
        s.headers.update({"Content-Type": "application/json"})
        s.post(endpoint, data=json.dumps(payload), timeout=5).raise_for_status()


def main() -> None:
    cfg = Config(
        endpoint=get_env_required("TRAFFIC_AGENT_ENDPOINT"),
        interval_sec=int(os.getenv("TRAFFIC_AGENT_INTERVAL", "60")),
        interface=os.getenv("TRAFFIC_AGENT_IFACE") or None,
    )

    # IP: сначала public (если доступен), иначе local
    ip = get_public_ip() or get_primary_local_ip()

    # CPU: "прогрев" — первый вызов даёт baseline
    psutil.cpu_percent(interval=None)

    prev_rx, prev_tx = read_net_bytes(cfg.interface)
    prev_ts = time.time()

    while True:
        now_ts = time.time()
        ts_int = int(now_ts)

        cpu = psutil.cpu_percent(interval=None)

        vm = psutil.virtual_memory()
        ram_mb = int(vm.used / (1024 * 1024))

        rx, tx = read_net_bytes(cfg.interface)
        dt = now_ts - prev_ts

        # Если счётчики сбросились (ребут/интерфейс), скорость считаем 0
        if rx < prev_rx or tx < prev_tx:
            download_bps = 0
            upload_bps = 0
        else:
            download_bps = bytes_per_sec_to_bps(rx - prev_rx, dt)
            upload_bps = bytes_per_sec_to_bps(tx - prev_tx, dt)

        payload = {
            "server_ip": ip,
            "timestamp": ts_int,
            "cpu": float(round(cpu, 1)),
            "ram_mb": ram_mb,
            "download_bps": int(download_bps),
            "upload_bps": int(upload_bps),
        }

        try:
            post_json(cfg.endpoint, payload)
        except Exception as e:
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] отправка не удалась: {e} payload={payload}")

        prev_rx, prev_tx = rx, tx
        prev_ts = now_ts

        # ровный интервал, учитывая время работы цикла
        sleep_for = cfg.interval_sec - (time.time() - now_ts)
        if sleep_for < 0:
            sleep_for = 0
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
PY

chmod +x "$AGENT_DIR/agent.py"

echo "4) Запись env-конфига: $ENV_FILE"
cat > "$ENV_FILE" <<EOF
# Auto-generated by install_agent.sh
TRAFFIC_AGENT_ENDPOINT=${ENDPOINT}
TRAFFIC_AGENT_INTERVAL=${INTERVAL}
TRAFFIC_AGENT_IFACE=${INTERFACE}
EOF
chmod 0644 "$ENV_FILE"

echo "5) Установка systemd unit: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Traffic Snapshots Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 ${AGENT_DIR}/agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "6) Перезапуск systemd + старт сервиса..."
systemctl daemon-reload
systemctl enable --now traffic_snapshots_agent.service
systemctl status traffic_snapshots_agent --no-pager -l || true

echo "=============================="
echo "✅ Установлено и запущено!"
echo "Статус:  sudo systemctl status traffic_snapshots_agent -l"
echo "Логи:    sudo journalctl -u traffic_snapshots_agent -f"
echo "Конфиг:  ${ENV_FILE}"
echo "=============================="
