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

-- L1-L5: task runs' cost rows, their tags in each of FOCUS's three key forms.
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, consumed_quantity, consumed_unit, billed_cost, tags, project)
VALUES ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-15T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 5, 'Hrs', 4.5, '{"RunId": "100-1", "TaskId": "net-v12"}', NULL),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-15T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', NULL, NULL, 0.3, '{"RunId": "100-1", "TaskId": "net-v12"}', NULL),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-20T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', NULL, NULL, 1.7, '{"user:RunId": "101-1", "user:TaskId": "net-v12"}', NULL),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-10T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', NULL, NULL, 16, '{"user_runid": "103-1", "user_taskid": "probe"}', NULL),
       ('test/views', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-01T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 3.5, 'Hrs', 7,
        '{"user:RunId": "99-1", "user:TaskId": "old", "user:Workflow": "train", "user:Profile": "gpu", "user:Campaign": "net-v11"}',
        'braveheart-trainer');

-- R1-R4: run records. R1 passed, R2 was interrupted, R3 is still running (a CPU
-- run), R4 was swept.
INSERT INTO cost.run_events (key, period, run_key, tags, event, at, project, campaign, kind, instance_type, accelerators,
                             market, zone, instance_id, hourly_usd, on_demand_hourly_usd, worst_case_usd, ceiling_usd,
                             max_hours, outcome, exit_code, interrupted_at, reason, links, attributes)
VALUES ('test/views', '2026-11', 'RunId=100-1;TaskId=net-v12', '{"RunId": "100-1", "TaskId": "net-v12"}', 'started',
        '2026-11-15T10:00:00Z', 'braveheart-trainer', 'net-v12', 'train', 'g6e.xlarge', 1, 'spot', 'use1-az4', 'i-1',
        1.0, 2.0, 12, 50, 6, NULL, NULL, NULL, NULL,
        '{"run": "https://github.com/acme/trainer/actions/runs/100/attempts/1", "pr": "https://github.com/acme/trainer/pull/88", "commit": "https://github.com/acme/trainer/commit/a1b2c3d4e5f6"}',
        '{"profile": "gpu"}'),
       ('test/views', '2026-11', 'RunId=100-1;TaskId=net-v12', '{"RunId": "100-1", "TaskId": "net-v12"}', 'finished',
        '2026-11-15T15:00:00Z', 'braveheart-trainer', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, 'passed', 0, NULL, NULL, NULL, NULL),
       ('test/views', '2026-11', 'RunId=101-1;TaskId=net-v12', '{"RunId": "101-1", "TaskId": "net-v12"}', 'started',
        '2026-11-20T08:00:00Z', 'braveheart-trainer', 'net-v12', 'train', 'g6e.xlarge', 1, 'spot', 'use1-az4', 'i-2',
        1.0, 2.0, 12, 50, 6, NULL, NULL, NULL, NULL,
        '{"run": "https://github.com/acme/trainer/actions/runs/101/attempts/1"}', '{"profile": "gpu"}'),
       ('test/views', '2026-11', 'RunId=101-1;TaskId=net-v12', '{"RunId": "101-1", "TaskId": "net-v12"}', 'finished',
        '2026-11-20T10:00:00Z', 'braveheart-trainer', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, 'interrupted', NULL, '2026-11-20T10:00:00Z', NULL, NULL, NULL),
       ('test/views', '2026-11', 'RunId=102-1;TaskId=datagen', '{"RunId": "102-1", "TaskId": "datagen"}', 'started',
        '2026-11-21T06:00:00Z', 'braveheart-selfplay', NULL, 'datagen', 'c7i.large', 0, 'on-demand', 'use1-az4', 'i-3',
        0.5, 0.5, 5, 10, 24, NULL, NULL, NULL, NULL, NULL, '{"profile": "cpu"}'),
       ('test/views', '2026-11', 'RunId=103-1;TaskId=probe', '{"RunId": "103-1", "TaskId": "probe"}', 'started',
        '2026-11-10T00:00:00Z', 'braveheart-trainer', NULL, 'train', 'g6e.xlarge', 1, 'spot', 'use1-az4', 'i-4',
        2.0, NULL, 8, 20, 4, NULL, NULL, NULL, NULL, NULL, '{"profile": "gpu"}'),
       ('test/views', '2026-11', 'RunId=103-1;TaskId=probe', '{"RunId": "103-1", "TaskId": "probe"}', 'swept',
        '2026-11-10T08:00:00Z', 'braveheart-trainer', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'leaked', NULL, NULL);
