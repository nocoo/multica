-- GitHub repository owner/name paths are case-insensitive, while the original
-- PR and pending-suite keys used case-sensitive TEXT columns. Consolidate old
-- variants before the application begins storing the lower-case identity.
--
-- The lock keeps webhook writes from reintroducing a case variant between
-- merging duplicate PRs and lower-casing their surviving identity.
BEGIN;

LOCK TABLE github_pull_request,
           issue_pull_request,
           github_pull_request_check_suite,
           github_pending_check_suite
IN SHARE ROW EXCLUSIVE MODE;

CREATE TEMP TABLE github_pr_identity_merge (
    legacy_id    UUID PRIMARY KEY,
    canonical_id UUID NOT NULL
) ON COMMIT DROP;

-- Prefer a merged snapshot when one exists, otherwise use the freshest GitHub
-- update. This prevents a stale open variant from blocking a merged PR's
-- close aggregate after identities are consolidated.
INSERT INTO github_pr_identity_merge (legacy_id, canonical_id)
SELECT id, canonical_id
FROM (
    SELECT
        id,
        FIRST_VALUE(id) OVER (
            PARTITION BY workspace_id, lower(repo_owner), lower(repo_name), pr_number
            ORDER BY
                CASE WHEN state = 'merged' THEN 0 ELSE 1 END,
                pr_updated_at DESC,
                updated_at DESC,
                id ASC
        ) AS canonical_id
    FROM github_pull_request
) ranked
WHERE id <> canonical_id;

-- Preserve every issue association while folding duplicate links. close_intent
-- is ORed because a valid historical closing declaration must not be lost.
WITH moved_links AS (
    SELECT DISTINCT ON (ipr.issue_id, merge.canonical_id)
        ipr.issue_id,
        merge.canonical_id AS pull_request_id,
        ipr.linked_by_type,
        ipr.linked_by_id,
        BOOL_OR(ipr.close_intent) OVER (
            PARTITION BY ipr.issue_id, merge.canonical_id
        ) AS close_intent,
        MIN(ipr.linked_at) OVER (
            PARTITION BY ipr.issue_id, merge.canonical_id
        ) AS linked_at
    FROM issue_pull_request ipr
    JOIN github_pr_identity_merge merge ON merge.legacy_id = ipr.pull_request_id
    ORDER BY ipr.issue_id, merge.canonical_id, ipr.linked_at ASC, ipr.pull_request_id ASC
)
INSERT INTO issue_pull_request (
    issue_id, pull_request_id, linked_by_type, linked_by_id, close_intent, linked_at
)
SELECT issue_id, pull_request_id, linked_by_type, linked_by_id, close_intent, linked_at
FROM moved_links
ON CONFLICT (issue_id, pull_request_id) DO UPDATE SET
    close_intent = issue_pull_request.close_intent OR EXCLUDED.close_intent,
    linked_at = LEAST(issue_pull_request.linked_at, EXCLUDED.linked_at);

DELETE FROM issue_pull_request ipr
USING github_pr_identity_merge merge
WHERE ipr.pull_request_id = merge.legacy_id;

-- Move CI suites to the survivor. A suite ID identifies one GitHub suite, so
-- retain its freshest observation if the duplicate PR rows both have a copy.
WITH moved_suites AS (
    SELECT DISTINCT ON (merge.canonical_id, suite.suite_id)
        merge.canonical_id AS pr_id,
        suite.suite_id,
        suite.head_sha,
        suite.app_id,
        suite.conclusion,
        suite.status,
        suite.updated_at
    FROM github_pull_request_check_suite suite
    JOIN github_pr_identity_merge merge ON merge.legacy_id = suite.pr_id
    ORDER BY merge.canonical_id, suite.suite_id, suite.updated_at DESC, suite.pr_id ASC
)
INSERT INTO github_pull_request_check_suite (
    pr_id, suite_id, head_sha, app_id, conclusion, status, updated_at
)
SELECT pr_id, suite_id, head_sha, app_id, conclusion, status, updated_at
FROM moved_suites
ON CONFLICT (pr_id, suite_id) DO UPDATE SET
    head_sha = EXCLUDED.head_sha,
    app_id = EXCLUDED.app_id,
    conclusion = EXCLUDED.conclusion,
    status = EXCLUDED.status,
    updated_at = EXCLUDED.updated_at
WHERE EXCLUDED.updated_at >= github_pull_request_check_suite.updated_at;

DELETE FROM github_pull_request_check_suite suite
USING github_pr_identity_merge merge
WHERE suite.pr_id = merge.legacy_id;

DELETE FROM github_pull_request pr
USING github_pr_identity_merge merge
WHERE pr.id = merge.legacy_id;

UPDATE github_pull_request
SET
    repo_owner = lower(repo_owner),
    repo_name = lower(repo_name)
WHERE repo_owner <> lower(repo_owner)
   OR repo_name <> lower(repo_name);

-- Pending suites have no foreign keys, so rebuilding their case-insensitive
-- key in one statement safely resolves conflicts while retaining the freshest
-- event for each GitHub suite.
WITH removed AS (
    DELETE FROM github_pending_check_suite
    RETURNING
        workspace_id,
        installation_id,
        repo_owner,
        repo_name,
        pr_number,
        suite_id,
        head_sha,
        app_id,
        conclusion,
        status,
        suite_updated_at,
        received_at
), canonical_pending AS (
    SELECT DISTINCT ON (
        workspace_id, lower(repo_owner), lower(repo_name), pr_number, suite_id
    )
        workspace_id,
        installation_id,
        lower(repo_owner) AS repo_owner,
        lower(repo_name) AS repo_name,
        pr_number,
        suite_id,
        head_sha,
        app_id,
        conclusion,
        status,
        suite_updated_at,
        received_at
    FROM removed
    ORDER BY
        workspace_id,
        lower(repo_owner),
        lower(repo_name),
        pr_number,
        suite_id,
        suite_updated_at DESC,
        received_at DESC,
        installation_id DESC
)
INSERT INTO github_pending_check_suite (
    workspace_id,
    installation_id,
    repo_owner,
    repo_name,
    pr_number,
    suite_id,
    head_sha,
    app_id,
    conclusion,
    status,
    suite_updated_at,
    received_at
)
SELECT
    workspace_id,
    installation_id,
    repo_owner,
    repo_name,
    pr_number,
    suite_id,
    head_sha,
    app_id,
    conclusion,
    status,
    suite_updated_at,
    received_at
FROM canonical_pending;

COMMIT;
