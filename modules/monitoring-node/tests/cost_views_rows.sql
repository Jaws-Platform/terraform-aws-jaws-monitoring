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

-- D1-D3: Databricks on Nov 20 (list price; periods of one day).
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_period_end, charge_category, service_name, sku_id, consumed_quantity, consumed_unit,
                        billed_cost, tags, project, serverless)
VALUES ('test/views', 'databricks', '2026-11', 'Databricks', 'ws-1', 'braveheart-prod', '2026-11-20T00:00:00Z',
        '2026-11-21T00:00:00Z', 'Usage', 'Databricks JOBS', 'JOBS_SERVERLESS', 10, 'DBU', 3.5, '{}', 'braveheart', true),
       ('test/views', 'databricks', '2026-11', 'Databricks', 'ws-1', 'braveheart-prod', '2026-11-20T00:00:00Z',
        '2026-11-21T00:00:00Z', 'Usage', 'Databricks ALL_PURPOSE', 'ALL_PURPOSE_CLASSIC', 4, 'DBU', 2.2, '{}', 'braveheart', false),
       ('test/views', 'databricks', '2026-11', 'Databricks', 'ws-2', NULL, '2026-11-20T00:00:00Z',
        '2026-11-21T00:00:00Z', 'Usage', 'Databricks SQL', 'SQL_PRO', 2, 'DBU', 1, '{}', NULL, false);

-- A1-A3: AWS rows carrying the workspace tag, in each of FOCUS's three key forms.
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags)
VALUES ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-20T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 1.3, '{"Workspace": "braveheart-prod"}'),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-20T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 0.2, '{"user:Workspace": "braveheart-prod"}'),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-19T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 0.1, '{"user_workspace": "braveheart-prod"}');
