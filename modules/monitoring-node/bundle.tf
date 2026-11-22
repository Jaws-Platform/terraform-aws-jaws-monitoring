# The config bundle: every file the stack runs with, as one JSON object the
# node's reconciler installs. Each file is built here as HCL and encoded, so the
# tests can decode and check it.
#
#   compose.yaml                             the services
#   prometheus/prometheus.yml                what Prometheus scrapes
#   grafana/...                              data sources, dashboards, alerting
#                                            (the grafana module, grafana.tf)
#   caddy/Caddyfile, blackbox/blackbox.yml   with a domain only
#
# secrets are SSM parameters the reconciler reads; generated values it makes
# once on the node. compose.yaml refers to both as $${NAME:?}, so a value the
# bundle forgot to name fails `compose up` instead of starting a service with
# an empty password. Config mounts go through /data/config/current, so a new
# release never changes a service's own definition; its config-hash label does.

locals {
  default_images = {
    "caddy"             = "docker.io/library/caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0"
    "grafana"           = "docker.io/grafana/grafana:13.3.1@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf"
    "prometheus"        = "docker.io/prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"
    "node-exporter"     = "docker.io/prom/node-exporter:v1.13.1@sha256:7296504d4ada44b7d7ab4431e27e9f9900d8488f8d55842f4b12ae2704e16dfe"
    "cadvisor"          = "gcr.io/cadvisor/cadvisor:v0.55.1@sha256:3de2bd5203120b866d74a9b283b2ffb8ec382fbf9dc321814700c6ea6f44ec57"
    "postgres"          = "docker.io/library/postgres:17.12-alpine3.24@sha256:f9cf3e1f0066f0eb0c48707d864f0ac5941e9ff454a072077d97a4d278d07d73"
    "postgres-exporter" = "docker.io/prometheuscommunity/postgres-exporter:v0.21.1@sha256:3b8e05a84282cd1199ad2fb6c66f362738bf4c68c1547d8f4226a34a7dd6d8d7"
    "blackbox-exporter" = "docker.io/prom/blackbox-exporter:v0.29.1@sha256:ea1c7aa3ef3f307cd03e85f34abb604478ccb90b567fc690da0cd9776da76b13"
  }
  images = merge(local.default_images, var.images)

  served           = var.domain != null
  grafana_root_url = local.served ? "https://${var.domain}" : "http://localhost:3000"

  # ---------------------------------------------------------------- files
  prometheus_config = yamlencode({
    global = {
      scrape_interval     = "15s"
      evaluation_interval = "1m"
      external_labels     = { node = var.name }
    }
    scrape_configs = concat(
      [
        { job_name = "prometheus", static_configs = [{ targets = ["localhost:9090"] }] },
        # node-exporter runs on the host network, to see the host's interfaces.
        { job_name = "node", static_configs = [{ targets = ["host.docker.internal:9100"] }] },
        { job_name = "cadvisor", static_configs = [{ targets = ["cadvisor:8080"] }] },
        { job_name = "postgres", static_configs = [{ targets = ["postgres-exporter:9187"] }] },
        { job_name = "grafana", static_configs = [{ targets = ["grafana:3000"] }] },
      ],
      local.served ? [
        {
          job_name       = "blackbox"
          metrics_path   = "/probe"
          params         = { module = ["http_2xx"] }
          static_configs = [{ targets = ["https://${var.domain}"] }]
          relabel_configs = [
            { source_labels = ["__address__"], target_label = "__param_target" },
            { source_labels = ["__param_target"], target_label = "instance" },
            { target_label = "__address__", replacement = "blackbox-exporter:9115" },
          ]
        },
      ] : [],
    )
  })

  blackbox_config = yamlencode({
    modules = {
      http_2xx = {
        prober  = "http"
        timeout = "10s"
        http    = { valid_status_codes = [200, 302], preferred_ip_protocol = "ip4" }
      }
    }
  })

  caddyfile = local.served ? templatefile("${path.module}/files/Caddyfile.tftpl", {
    domain     = var.domain
    acme_email = var.acme_email == null ? "" : var.acme_email
  }) : ""

  bundle_files = merge(
    { "prometheus/prometheus.yml" = local.prometheus_config },
    local.served ? {
      "caddy/Caddyfile"       = local.caddyfile
      "blackbox/blackbox.yml" = local.blackbox_config
    } : {},
    module.grafana.files,
    local.cost_sync_files,
  )

  # What each service mounts, hashed into its label so `compose up -d`
  # recreates exactly the services whose files changed.
  config_hash = {
    for service, prefix in { grafana = "grafana/", caddy = "caddy/", "blackbox-exporter" = "blackbox/" } :
    service => sha256(join("\n", [for k in sort(keys(local.bundle_files)) : "${k}:${sha256(local.bundle_files[k])}" if startswith(k, prefix)]))
  }

  # ------------------------------------------------------------- services
  restart = "unless-stopped"

  services = merge(
    {
      postgres = {
        image     = local.images["postgres"]
        restart   = local.restart
        mem_limit = "512m"
        environment = {
          POSTGRES_USER     = "monitoring"
          POSTGRES_PASSWORD = "$${POSTGRES_PASSWORD:?}"
          POSTGRES_DB       = "grafana"
        }
        volumes     = ["/data/postgres:/var/lib/postgresql/data"]
        healthcheck = { test = ["CMD-SHELL", "pg_isready -U monitoring -d grafana"], interval = "10s", timeout = "5s", retries = 10 }
      }

      grafana = merge(
        {
          image      = local.images["grafana"]
          restart    = local.restart
          mem_limit  = "512m"
          depends_on = { postgres = { condition = "service_healthy" } }
          environment = merge({
            GF_DATABASE_TYPE                                  = "postgres"
            GF_DATABASE_HOST                                  = "postgres:5432"
            GF_DATABASE_NAME                                  = "grafana"
            GF_DATABASE_USER                                  = "monitoring"
            GF_DATABASE_PASSWORD                              = "$${POSTGRES_PASSWORD:?}"
            GF_SECURITY_ADMIN_USER                            = "$${GF_SECURITY_ADMIN_USER:?}"
            GF_SECURITY_ADMIN_PASSWORD                        = "$${GF_SECURITY_ADMIN_PASSWORD:?}"
            GF_SECURITY_DISABLE_INITIAL_ADMIN_PASSWORD_CHANGE = "true"
            GF_SECURITY_COOKIE_SECURE                         = local.served ? "true" : "false"
            GF_AUTH_ANONYMOUS_ENABLED                         = "false"
            GF_USERS_ALLOW_SIGN_UP                            = "false"
            GF_SERVER_ROOT_URL                                = local.grafana_root_url
            GF_ANALYTICS_REPORTING_ENABLED                    = "false"
            GF_ANALYTICS_CHECK_FOR_UPDATES                    = "false"
            },
            # Each Slack webhook, for the contact points to expand.
            { for env in keys(local.slack_secrets) : env => "$${${env}:?}" },
            # The cost database's read-only user, for the Cost data source.
            { for env in(local.cost_on ? ["COST_READER_PASSWORD"] : []) : env => "$${${env}:?}" },
          )
          volumes = [
            "/data/config/current/grafana/provisioning:/etc/grafana/provisioning:ro",
            "/data/config/current/grafana/dashboards:/var/lib/grafana/dashboards:ro",
            "/data/grafana:/var/lib/grafana",
          ]
          labels = { "monitoring.config-hash" = local.config_hash["grafana"] }
        },
        # Without a domain, the loopback only, for a Session Manager port forward.
        { for k, v in { ports = ["127.0.0.1:3000:3000"] } : k => v if !local.served },
      )

      prometheus = {
        image     = local.images["prometheus"]
        restart   = local.restart
        mem_limit = "1g"
        command = [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--storage.tsdb.retention.time=${var.prometheus_retention.time}",
          "--storage.tsdb.retention.size=${var.prometheus_retention.size_gb}GB",
          "--web.enable-lifecycle",
        ]
        volumes     = ["/data/config/current/prometheus:/etc/prometheus:ro", "/data/prometheus:/prometheus"]
        extra_hosts = ["host.docker.internal:host-gateway"]
        labels      = { "monitoring.config-hash" = sha256(local.bundle_files["prometheus/prometheus.yml"]) }
      }

      "node-exporter" = {
        image        = local.images["node-exporter"]
        restart      = local.restart
        mem_limit    = "64m"
        network_mode = "host"
        pid          = "host"
        volumes      = ["/:/host:ro,rslave"]
        command = [
          "--path.rootfs=/host",
          "--collector.textfile.directory=/host/var/lib/node_exporter/textfile",
          "--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+)($$|/)",
        ]
      }

      cadvisor = {
        image      = local.images["cadvisor"]
        restart    = local.restart
        mem_limit  = "256m"
        privileged = true
        devices    = ["/dev/kmsg"]
        volumes    = ["/:/rootfs:ro", "/var/run:/var/run:ro", "/sys:/sys:ro", "/var/lib/docker/:/var/lib/docker:ro", "/dev/disk/:/dev/disk:ro"]
        command = [
          "--docker_only=true",
          "--housekeeping_interval=30s",
          "--store_container_labels=false",
          "--disable_metrics=advtcp,cpu_topology,cpuset,hugetlb,memory_numa,percpu,process,referenced_memory,resctrl,sched,tcp,udp",
        ]
      }

      "postgres-exporter" = {
        image      = local.images["postgres-exporter"]
        restart    = local.restart
        mem_limit  = "64m"
        depends_on = { postgres = { condition = "service_healthy" } }
        environment = {
          DATA_SOURCE_URI  = "postgres:5432/postgres?sslmode=disable"
          DATA_SOURCE_USER = "monitoring"
          DATA_SOURCE_PASS = "$${POSTGRES_PASSWORD:?}"
        }
      }
    },
    { for k, v in local.web_services : k => v if local.served },
  )

  # With a domain: Caddy in front of Grafana, and a probe of the public address.
  web_services = {
    caddy = {
      image      = local.images["caddy"]
      restart    = local.restart
      mem_limit  = "128m"
      ports      = ["80:80", "443:443"]
      depends_on = ["grafana"]
      volumes    = ["/data/config/current/caddy/Caddyfile:/etc/caddy/Caddyfile:ro", "/data/caddy:/data"]
      labels     = { "monitoring.config-hash" = local.config_hash["caddy"] }
    }

    "blackbox-exporter" = {
      image     = local.images["blackbox-exporter"]
      restart   = local.restart
      mem_limit = "64m"
      command   = ["--config.file=/etc/blackbox_exporter/blackbox.yml"]
      volumes   = ["/data/config/current/blackbox:/etc/blackbox_exporter:ro"]
      labels    = { "monitoring.config-hash" = local.config_hash["blackbox-exporter"] }
    }
  }

  bundle = {
    schema = "monitoring-bundle-1"
    files  = merge(local.bundle_files, { "compose.yaml" = yamlencode({ name = "monitoring", services = local.services }) })
    secrets = merge(
      {
        GF_SECURITY_ADMIN_USER     = var.grafana_admin.user_parameter
        GF_SECURITY_ADMIN_PASSWORD = var.grafana_admin.password_parameter
      },
      local.slack_secrets,
    )
    generated = concat(["POSTGRES_PASSWORD"], local.cost_on ? ["COST_READER_PASSWORD"] : [])
  }

  bundle_json = jsonencode(local.bundle)
}
