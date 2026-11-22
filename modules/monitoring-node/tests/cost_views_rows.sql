-- Rows for the cost views' cases (the "cost views" section of
-- test-cost-sync-postgres.sh), judged at cost.now = 2026-11-21T12:00:00Z unless a
-- case says so. AWS rows are account 570327089884, named production.

-- P1, P2: project web-app on Nov 20, by component.
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags, project, component, environment)
VALUES ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-20T00:00:00Z', 'Usage',
        'Amazon CloudFront', 2, '{"Project": "web-app"}', 'web-app', 'site', 'prod'),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-20T00:00:00Z', 'Usage',
        'AWS Lambda', 1, '{"Project": "web-app"}', 'web-app', 'api', 'prod');
