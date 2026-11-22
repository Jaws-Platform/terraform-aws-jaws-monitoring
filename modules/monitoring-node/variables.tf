variable "name" {
  description = "Names the instance, its role, security group, data volume (`<name>-data`), config bucket (`<name>-config-<account>`) and parameters (`/<name>/node/…`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 1 to 40 lowercase letters, digits or hyphens."
  }
}

variable "vpc_id" {
  description = "The VPC of the node's subnet."
  type        = string
}

variable "subnet_id" {
  description = "A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume."
  type        = string
}

variable "instance_type" {
  description = "The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance."
  type        = string
  default     = "t9g.medium"
}

variable "ami_name" {
  description = "The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached."
  type        = string

  validation {
    condition     = length(trimspace(var.ami_name)) > 0
    error_message = "ami_name must name an image."
  }
}

variable "root_volume_gb" {
  description = "Size of the root volume: the OS, the images and a 2 GB swap file."
  type        = number
  default     = 12

  validation {
    condition     = var.root_volume_gb >= 8
    error_message = "root_volume_gb must be at least 8."
  }
}

variable "data_volume_gb" {
  description = "Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced."
  type        = number
  default     = 30

  validation {
    condition     = var.data_volume_gb >= 10
    error_message = "data_volume_gb must be at least 10."
  }
}

variable "domain" {
  description = "The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward."
  type        = string
  default     = null
}

variable "zone_id" {
  description = "The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot."
  type        = string
  default     = null

  validation {
    condition     = var.domain == null || var.zone_id != null
    error_message = "zone_id is required when domain is set."
  }
}

variable "acme_email" {
  description = "Optional contact address for Let's Encrypt."
  type        = string
  default     = null
}

variable "grafana_admin" {
  description = "The SSM SecureString parameters holding Grafana's admin user name and password. The node reads them at every reconcile; set them before the first apply."
  type = object({
    user_parameter     = string
    password_parameter = string
  })
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). Keep size_gb well under data_volume_gb."
  type = object({
    time    = optional(string, "365d")
    size_gb = optional(number, 12)
  })
  default = {}
}

variable "snapshots" {
  description = "Daily snapshots of the data volume (Data Lifecycle Manager), at time_utc, keeping the last `keep`."
  type = object({
    enabled  = optional(bool, false)
    time_utc = optional(string, "03:00")
    keep     = optional(number, 7)
  })
  default = {}
}

variable "images" {
  description = "Container images to use instead of the module's digest-pinned defaults, by service name (see the README)."
  type        = map(string)
  default     = {}
}
