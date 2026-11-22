-- Rows for the cost model's cases (test-cost-sync-postgres.sh), at fixed UTC
-- dates, judged with cost.now = 2026-11-21T12:00:00Z unless a case says so.
-- One account: 570327089884, named production.

-- alpha: $10 a day from Oct 1 to Nov 18, then $50 on Nov 21.
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags, project)
SELECT 'test/model', 'aws', to_char(d, 'YYYY-MM'), 'AWS', '570327089884', 'production', d, 'Usage',
       'Amazon Elastic Compute Cloud', 10, '{"Project": "alpha"}', 'alpha'
FROM generate_series('2026-10-01T00:00:00Z'::timestamptz, '2026-11-18T00:00:00Z', interval '1 day') AS d;

INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags, project)
VALUES ('test/model', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-21T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 50, '{"Project": "alpha"}', 'alpha'),
-- beta: $5 on Nov 21 only, its first day.
       ('test/model', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-21T00:00:00Z', 'Usage',
        'Amazon Elastic Compute Cloud', 5, '{"Project": "beta"}', 'beta'),
-- untagged S3, new on Nov 21; and tax, which is never untagged.
       ('test/model', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-21T00:00:00Z', 'Usage',
        'Amazon Simple Storage Service', 3, '{}', NULL),
       ('test/model', 'aws', '2026-11', 'AWS', '570327089884', 'production', '2026-11-21T00:00:00Z', 'Tax',
        'Tax', 4, '{}', NULL);

-- untagged VPC (a public IPv4 address): $0.60 every day from Nov 5 to Nov 21.
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags, project)
SELECT 'test/model', 'aws', '2026-11', 'AWS', '570327089884', 'production', d, 'Usage',
       'Amazon Virtual Private Cloud', 0.6, '{}', NULL
FROM generate_series('2026-11-05T00:00:00Z'::timestamptz, '2026-11-21T00:00:00Z', interval '1 day') AS d;
