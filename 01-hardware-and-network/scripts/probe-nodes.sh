#!/usr/bin/env bash
# Probe all homelab nodes and output README-ready hardware table.
# Usage:
#   export SSH_USER=ubuntu
#   export SSHPASS=yourpassword
#   bash probe-nodes.sh

set -euo pipefail

: "${SSHPASS:?Please export SSHPASS=yourpassword}"
: "${SSH_USER:=ubuntu}"

if ! command -v sshpass &>/dev/null; then
  echo "sshpass not found. Install with: brew install hudochenkov/sshpass/sshpass"
  exit 1
fi

NODES=(
  "truenas:192.168.0.180"
  "node01:192.168.0.104"
  "node02:192.168.0.105"
  "pi-node01:192.168.0.201"
  "pi-node02:192.168.0.202"
  "pi-node03:192.168.0.203"
  "pi-node04:192.168.0.204"
)

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR"

PROBE_CMD='
ARCH=$(uname -m)
RAM_KB=$(grep MemTotal /proc/meminfo | awk "{print \$2}")
RAM_GB=$(( (RAM_KB + 524288) / 1048576 ))
CORES=$(nproc)
DISKS=$(lsblk -d -o NAME,SIZE -n 2>/dev/null | grep -v "loop\|sr0" | awk "{printf \"%s:%s \",\$1,\$2}" | xargs)
MODEL=$(grep -m1 "Model\b\|model name\|Hardware" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "?")
printf "%s|%s|%sGB|%s|%s|%s\n" "$(hostname)" "$ARCH" "$RAM_GB" "$CORES" "$DISKS" "$MODEL"
'

echo ""
echo "Probing nodes..."
echo ""
echo "| Node | IP | Hostname | Arch | RAM | Cores | Disks | Model |"
echo "|---|---|---|---|---|---|---|---|"

for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"

  result=$(sshpass -e ssh $SSH_OPTS "${SSH_USER}@${ip}" "$PROBE_CMD" 2>&1) && status=ok || status=fail

  if [[ "$status" == "fail" ]]; then
    echo "| $name | $ip | — | — | — | — | — | SSH failed: ${result} |"
    continue
  fi

  IFS='|' read -r hostname arch ram cores disks model <<< "$result"
  echo "| $name | $ip | $hostname | $arch | $ram | $cores | $disks | $model |"
done

echo ""
echo "---"
echo "Copy the table rows above into 01-hardware-and-network/README.md"
echo "Then update configs/nodes.env role aliases (SERVER_A_IP etc.) to match."
