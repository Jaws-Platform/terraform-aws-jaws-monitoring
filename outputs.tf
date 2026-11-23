output "normalizer" {
  description = "The billing normalizer's outputs: its function, role, log group, schedule, and where it writes."
  value = {
    function_name  = module.normalizer.function_name
    function_arn   = module.normalizer.function_arn
    role_name      = module.normalizer.role_name
    role_arn       = module.normalizer.role_arn
    log_group_name = module.normalizer.log_group_name
    schedule_name  = module.normalizer.schedule_name
    outputs        = module.normalizer.outputs
  }
}

output "node" {
  description = "The monitoring node's outputs: its instance, address, role, config bucket, parameters, data volume, Grafana URL and watchdog."
  value = {
    instance_id            = module.node.instance_id
    public_ip              = module.node.public_ip
    security_group_id      = module.node.security_group_id
    role_name              = module.node.role_name
    role_arn               = module.node.role_arn
    config_bucket          = module.node.config_bucket
    parameter_prefix       = module.node.parameter_prefix
    data_volume_id         = module.node.data_volume_id
    grafana_url            = module.node.grafana_url
    watchdog_function_name = module.node.watchdog_function_name
  }
}

output "off_hours_page_domain_name" {
  description = "The off-hours page's CloudFront domain name (null without the page)."
  value       = module.node.off_hours_page_domain_name
}
