# working-on-issues source map

Evidence layer for `SKILL.md`. Every contract the skill states is traced to a
current `file:line` here. Lines were re-derived against `feat/builtin-skills`
after the latest `main` merge; the prior skill cited pre-merge lines that have
since moved (see the "drifted" column). Re-confirm with the verification command
at the bottom before relying on an exact line.

## `multica issue pull-requests` — read PR links from Multica

| Behavior | File:line | Drifted from |
|---|---|---|
| CLI command `pull-requests <id>` (alias `prs`) | `server/cmd/multica/cmd_issue.go:105` | `:104` |
| `runIssuePullRequests` handler | `server/cmd/multica/cmd_issue.go:540` | `:507` |
| Calls `GET /api/issues/<id>/pull-requests` | `server/cmd/multica/cmd_issue.go:555` | `:522` |
| API route registration | `server/cmd/server/router.go:759` | `:480` |
| Handler `ListPullRequestsForIssue` → `Queries.ListPullRequestsByIssue` | `server/internal/handler/github.go:807,812` | `:466,471` |
| Row → response mapper `issuePullRequestRowToResponse` | `server/internal/handler/github.go:166` | `:149` |

The listing command resolves the issue ref, GETs the endpoint, and (for
`--output json`) prints the raw `{"pull_requests": [...]}` body. Its only flag is
`--output`; the default `table` shows `NUMBER STATE TITLE URL`.

### Re-sync a historical PR

| Behavior | File:line |
|---|---|
| CLI `pull-requests sync <issue-id>` registration | `server/cmd/multica/cmd_issue.go:112,273,311-313` |
| CLI resolves the issue then POSTs the current workspace endpoint | `server/cmd/multica/cmd_issue.go:569-603` |
| Admin-only route registration | `server/cmd/server/router.go:630` |
| Handler validates input, tries the workspace's installations, and runs the normal PR processor | `server/internal/handler/github.go:626-745` |
| App JWT → installation access-token exchange | `server/internal/handler/github.go:508-550` |
| Current PR GET through the installation token | `server/internal/handler/github.go:768-803` |

Sync reuses `handlePullRequestEventWithOptions` (`github.go:1069`) after fetching
a current PR snapshot. Its normal PR upsert and `LinkIssueToPullRequest` conflict
handling are therefore the idempotence mechanism; a second sync updates the same
rows. `canonicalGitHubRepository` (`github.go:757-763`) lowercases repository
identity for sync, pull-request webhook, and check-suite webhook lookups. Sync
requires the App ID + private key so the server can exchange the App JWT for an
installation token. The route is owner/admin-only because it asks GitHub for data
on behalf of the workspace.

Before sync processes a terminal fetched PR, it checks for a PR row that was
already `merged` (`github.go:675-692`). Only an existing `merged` → fetched
`merged` transition passes `PreserveExistingMergedCloseIntent` into the normal
processor (`:714-716`): existing conflict rows retain their merge-time close
intent, while new links use the current snapshot (`github.go:1162-1191`). A
`closed` → `merged` transition deliberately recomputes the close intent.

Migration `server/migrations/122_github_repository_identity.up.sql` locks the
four identity-bearing tables, picks one survivor per lower-cased PR key, merges
issue links with `close_intent = OR`, moves the freshest CI suite, and rebuilds
the pending-suite keys. The legacy-row migration followed by sync is exercised
in `TestGitHubRepositoryIdentityMigration_ConsolidatesLegacyRowsForSync`
(`server/internal/handler/github_test.go`).

## PR response shape

`GitHubPullRequestResponse` struct: `server/internal/handler/github.go:68`. JSON
fields the agent can read off each element of `pull_requests`:

- `number` (`json:"number"`, line 73)
- `html_url` (`json:"html_url"`, line 76)
- `title` (`json:"title"`, line 74)
- `state` (`json:"state"`, line 75) — the folded lifecycle enum (see below)
- `merged_at` (`json:"merged_at"`, line 80), `closed_at` (line 81)
- `mergeable_state` (`json:"mergeable_state"`, line 87) — mirrors GitHub; UI only
  surfaces `clean`/`dirty`, other values round-trip as unknown
- `checks_conclusion` (`json:"checks_conclusion"`, line 91) — aggregated
  `"passed"`/`"failed"`/`"pending"` or `null` (no observed suite)
- `checks_passed` / `checks_failed` / `checks_pending` (lines 95-97) — per-suite
  counts; `aggregateChecksConclusion` (line 200) folds them into
  `checks_conclusion`

There is **no** standalone `draft` or `merged` boolean in the response. The
PR lifecycle is encoded in the single `state` string by `derivePRState`
(`server/internal/handler/github.go:1470`):

```
merged   → if PullRequest.Merged
closed   → else if PullRequest.State == "closed"
draft    → else if PullRequest.Draft
open     → otherwise
```

`derivePRState` is called when the webhook upserts the row
(`server/internal/handler/github.go:1093`), so `state` is what the list endpoint
returns. "Is it merged?" = `state == "merged"` (or `merged_at != null`); "is it a
draft?" = `state == "draft"`. Combine with `checks_conclusion` for CI status.

## Two distinct webhook paths: link vs close-intent

Both run inside the `pull_request` webhook handler, gated by the workspace
auto-link flag (`workspaceAutoLinkPRsEnabled`, `github.go:1554`).

### Path 1 — link (title OR body OR branch)

- `extractIdentifiers` regex helper: `server/internal/handler/github.go:1508`
- driving regex `identifierRe` (`\b([a-z][a-z0-9]{1,9})-(\d+)\b`, case-insensitive):
  `server/internal/handler/github.go:831`
- call site: `server/internal/handler/github.go:1145` —
  `extractIdentifiers(p.PullRequest.Title, p.PullRequest.Body, p.PullRequest.Head.Ref)`

Every `PREFIX-NUMBER` mention in **title, body, or branch** resolves to an issue
in the workspace and writes a link row (`LinkIssueToPullRequest`, `github.go:1185`).
This is what `multica issue pull-requests` later reads back.

Drifted from the prior skill's `github.go:1145` citation, which pointed at the old
call-site location for the link logic.

### Path 2 — close intent (title OR body only, keyword-adjacent)

- `extractClosingIdentifiers` regex helper: `server/internal/handler/github.go:1531`
- driving regex `closingIdentifierRe`
  (`\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[:\s]+([a-z][a-z0-9]{1,9})-(\d+)\b`):
  `server/internal/handler/github.go:842-844`
- call site: `server/internal/handler/github.go:1154` —
  `extractClosingIdentifiers(p.PullRequest.Title, p.PullRequest.Body)` (no branch arg)

Only a `PREFIX-NUMBER` immediately after a closing keyword
(`Closes`/`Fixes`/`Resolves`, optional `:` then whitespace) sets the link row's
`close_intent` flag — the gate that auto-advances the issue to `done` on merge.
`Fix MUL-1` closes; `Fix login MUL-1` does not (adjacency). Branch names are
deliberately excluded (function doc, `github.go:1524-1530`): a branch like
`mul-1/fix-login` links but must never declare close intent.

Drifted from the prior skill's `github.go:1154` citation.

Net: a bare title prefix (`MUL-2759: ...`) or a branch ref links only;
`Closes MUL-2759` links **and** records close intent.

## Status side effects (enqueue contracts)

| Behavior | File:line | Drifted from |
|---|---|---|
| Create-time: agent-assigned, non-backlog issue enqueues immediately | `server/internal/handler/issue.go:2534-2535` | `:2263-2264` |
| `shouldEnqueueAgentTask` returns false for `backlog` (parking lot) | `server/internal/handler/issue.go:2663-2667` | `:2644-2648` |
| Backlog → non-backlog (not done/cancelled) enqueues on update | `server/internal/handler/issue.go:2555-2562` | `:2537-2540` |
| Same contract in batch update | `server/internal/handler/issue.go:3046-3052` | `:3021-3024` |
| Child → `done` posts a system comment on the parent | `server/internal/handler/issue_child_done.go:51` (`notifyParentOfChildDone`; doc comment at `:15`) | func def `:51` |

Creation with `--status todo` (or any non-backlog status) on an agent-assigned
issue fires the agent immediately; `--status backlog` parks it with the assignee
set but no trigger. Promoting `backlog → todo` later fires it then (update path,
line 2537).

## Metadata CLI

| Behavior | File:line |
|---|---|
| `multica issue metadata set <issue-id> --key --value [--type]` | `server/cmd/multica/cmd_issue_metadata.go:80,109-111` |
| `multica issue metadata delete <issue-id> --key` | `server/cmd/multica/cmd_issue_metadata.go:93,113` |
| API routes (PUT/DELETE `/metadata/{key}`) | `server/cmd/server/router.go:478-479` |

`--value` is JSON-parsed by default (bool/number sniff); `--type` forces
`string`/`number`/`bool`.

## Verification command

Re-derive any line above before depending on it:

```bash
cd server
grep -n 'pull-requests <id>'                 cmd/multica/cmd_issue.go
grep -n 'ListPullRequestsForIssue'           cmd/server/router.go internal/handler/github.go
grep -n 'func issuePullRequestRowToResponse\|type GitHubPullRequestResponse struct\|func derivePRState\|func extractIdentifiers\|func extractClosingIdentifiers\|closingIdentifierRe' internal/handler/github.go
grep -n 'extractIdentifiers(\|extractClosingIdentifiers(\|derivePRState(' internal/handler/github.go
grep -n 'prevIssue.Status == "backlog"\|func (h \*Handler) shouldEnqueueAgentTask' internal/handler/issue.go
grep -n 'func notifyParentOfChildDone'       internal/handler/issue_child_done.go
```
