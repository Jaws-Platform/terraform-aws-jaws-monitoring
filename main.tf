# Root module: a placeholder for now. It creates nothing.
#
# A later release turns it into the all-in-one composition: the billing
# normalizer and the monitoring node wired together in one account. Until then,
# use the submodules directly:
#
#   modules/billing-bucket       the bucket every billing source delivers into,
#                                which never loses raw data
#   modules/aws-billing-export   the FOCUS 1.2 daily AWS Data Export, created
#                                in the account whose bill it exports (the
#                                payer, for organization-wide data)
#   modules/billing-normalizer   the hourly Lambda that rebuilds each changed
#                                billing period as FOCUS-aligned Parquet
#   modules/monitoring-node      the instance running Grafana, Prometheus and
#                                the exporters, configured by a bundle
