# The bootstrap: cloud-init writes node.env, the three scripts and the systemd
# units, and enables them. node.env lines are shell-quoted KEY='value', read by
# bash (`source`) and by the reconciler.

locals {
  compose_version = "v5.6.1"
  compose_sha256  = "42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d"

  node_env_values = {
    NAME             = var.name
    REGION           = local.region
    PARAMETER_PREFIX = local.parameter_prefix
    CONFIG_BUCKET    = local.config_bucket
    DATA_VOLUME_ID   = aws_ebs_volume.data.id
    DOMAIN           = var.domain == null ? "" : var.domain
    ZONE_ID          = var.zone_id == null ? "" : var.zone_id
    COMPOSE_VERSION  = local.compose_version
    COMPOSE_SHA256   = local.compose_sha256
  }

  node_env = join("\n", [
    for k in sort(keys(local.node_env_values)) : "${k}='${replace(local.node_env_values[k], "'", "'\"'\"'")}'"
  ])

  user_data = templatefile("${path.module}/files/user-data.yaml.tftpl", {
    node_env             = local.node_env
    bootstrap_script     = base64gzip(file("${path.module}/files/monitoring-bootstrap.sh"))
    reconcile_script     = base64gzip(file("${path.module}/files/monitoring-reconcile.py"))
    release_check_script = base64gzip(file("${path.module}/files/monitoring-release-check.sh"))
  })
}
