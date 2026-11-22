#!/usr/bin/env bash
#
# monitoring-bootstrap: prepare the monitoring node, at every boot, before Docker.
#
# Installed by the monitoring-node module (monitoring-bootstrap.service). Every
# step is idempotent:
#
#   1. mount the data volume at /data (formatted xfs only if it has no
#      filesystem: a reattached volume keeps its data), and lay out its
#      directories with the owners the containers run as;
#   2. a 2 GB swap file on the root volume, for start-up spikes;
#   3. Docker's log rotation;
#   4. the Docker Compose plugin, at the pinned version, installed only if its
#      checksum matches;
#   5. with a domain, upsert the node's A record to its current public address
#      (it changes on every stop and start).
#
# Configuration: /etc/monitoring/node.env.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/monitoring/node.env

log() { echo "monitoring-bootstrap: $*"; }

# ------------------------------------------------------------------ /data
mount_data() {
  local serial device uuid
  serial="${DATA_VOLUME_ID//-/}"
  device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${serial}"
  # Terraform attaches the volume after the instance starts: wait for it.
  for _ in $(seq 1 120); do
    [[ -e "$device" ]] && break
    sleep 5
  done
  if [[ ! -e "$device" ]]; then
    log "data volume ${DATA_VOLUME_ID} is not attached"
    return 1
  fi
  if ! blkid "$device" > /dev/null 2>&1; then
    log "formatting the new data volume ${DATA_VOLUME_ID}"
    mkfs.xfs -L monitoring-data "$device"
  fi
  uuid="$(blkid -s UUID -o value "$device")"
  mkdir -p /data
  if ! grep -q "UUID=${uuid} /data " /etc/fstab; then
    echo "UUID=${uuid} /data xfs defaults,nofail 0 2" >> /etc/fstab
  fi
  mountpoint -q /data || mount /data

  mkdir -p /data/prometheus /data/grafana /data/postgres /data/caddy /data/config/releases /data/secrets
  chown 65534:65534 /data/prometheus
  chown 472:0 /data/grafana
  chmod 0700 /data/secrets
}

# ------------------------------------------------------------------- swap
swap_file() {
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile
    chmod 0600 /swapfile
    mkswap /swapfile > /dev/null
  fi
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
}

# ----------------------------------------------------------------- docker
docker_logs() {
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
JSON
}

compose_plugin() {
  local target=/usr/libexec/docker/cli-plugins/docker-compose tmp
  if [[ -x "$target" ]] && echo "${COMPOSE_SHA256}  ${target}" | sha256sum -c --status -; then
    return 0
  fi
  tmp="$(mktemp)"
  curl -fsSL --retry 5 --retry-delay 5 -o "$tmp" \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-aarch64"
  if ! echo "${COMPOSE_SHA256}  ${tmp}" | sha256sum -c --status -; then
    rm -f "$tmp"
    log "the Compose plugin ${COMPOSE_VERSION} does not match its pinned checksum"
    return 1
  fi
  install -D -m 0755 "$tmp" "$target"
  rm -f "$tmp"
}

# -------------------------------------------------------------------- dns
dns_record() {
  [[ -n "${DOMAIN:-}" ]] || return 0
  local token ip batch
  token="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
  ip="$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/public-ipv4)"
  batch="{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${DOMAIN}\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${ip}\"}]}}]}"
  for attempt in 1 2 3 4 5; do
    if aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$batch" > /dev/null; then
      log "${DOMAIN} -> ${ip}"
      return 0
    fi
    sleep $((attempt * 10))
  done
  log "could not upsert ${DOMAIN}"
  return 1
}

mount_data
swap_file
docker_logs
compose_plugin
dns_record
