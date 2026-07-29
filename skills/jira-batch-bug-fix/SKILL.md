---
name: jira-batch-bug-fix
description: Use when the user asks to batch-fix Jira bugs found by a Jira label under a main/parent ticket — e.g. "修复 label XXX 下的所有 bug", "batch fix bugs for HT5-272", or provides a Jira label plus a main ticket ID and asks to analyze and fix each unresolved bug ticket one by one. Also use when the user later reports "测试通过 / tests passed" for a previous batch-fix round (phase 2: bulk status transition).
---

# Jira Batch Bug Fix (by Label + Main Ticket)

Batch-analyze and fix all unresolved Jira bug tickets that carry a given label, on the code branches belonging to a main (parent) ticket. Two phases:

- **Phase 1 (fix round)**: find bugs → user picks scope → prepare workspace → analyze each → transition all → fix in parallel (one subagent per ticket) → PR to `develop` → STOP and wait for the user's test feedback.
- **Phase 2 (after user says tests passed)**: transition all fixed tickets to `TEST SERVER(VERIFYING)`.

## Required inputs

Ask the user if missing (both are required before doing anything):
1. **Jira label** (used to find bug tickets)
2. **Main ticket ID** (e.g. `HT5-272` — used to locate the working branches)

## Step 0 — Preflight (all three must pass before Step 1)

**1. Atlassian MCP connected.** Every Jira read/transition in this skill goes through the Atlassian MCP server — without it the skill cannot run. Probe by calling `getAccessibleAtlassianResources`:

- **Succeeds** → save the cloudId and reuse it for every later call.
- **The tool does not exist in this session** (no Atlassian MCP tools at all) → the MCP server is not installed. STOP and tell the user to connect it, then start a new session:

  ```bash
  claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse
  ```

  (or add the Atlassian connector via `/mcp` / claude.ai connectors, whichever they use).
- **Only an `authenticate` tool exists, or the probe fails with an auth error** → the server is installed but not authorized. Call the `authenticate` tool, give the user the OAuth URL to open in their browser, and complete the flow (submit the callback URL if the tool requires it). Re-probe until it succeeds.

**2. Jira REST credentials** — the MCP server cannot serve attachment binaries (screenshots), so images are downloaded via the Jira REST API:

```bash
[ -n "$JIRA_EMAIL" ] && [ -n "$JIRA_API_TOKEN" ] && echo OK || echo MISSING
```

If MISSING, stop and ask the user to create a token at https://id.atlassian.com/manage-profile/security/api-tokens and add to `~/.zshrc`:

```bash
export JIRA_EMAIL="<their-atlassian-email>"
export JIRA_API_TOKEN="<token>"
```

Never hardcode or echo the token value.

**3. GitHub CLI authenticated** (needed for PR creation): `gh auth status`. If not logged in, stop and ask the user to run `gh auth login`.

Report all failed checks together in one message (don't make the user fix them one at a time), then stop until they're resolved.

**Resuming an interrupted round:** if a previous run died mid-round (API error, session loss), re-run with the same label + main ticket. Existing `shared-docs/bug_fix/<TICKET>.md` docs, git log on the round branches, and current Jira statuses show what was already done — skip completed tickets, continue from the first unfinished one.

## Phase 1 — Fix round

### Step 1: Find unresolved bug tickets

Use `searchJiraIssuesUsingJql`:

```
labels = "<LABEL>" AND status IN (Open, Reopened) ORDER BY key ASC
```

Example: `labels = "bug_0730_customreport" AND status IN (Open, Reopened) ORDER BY key ASC`. Only Open/Reopened tickets are picked up — anything already in progress or beyond is excluded.

If zero tickets, stop and report.

### Step 1b: Let the user pick the round scope

Show the found tickets (key, priority, summary), then use **AskUserQuestion** to let the user choose: **fix all**, or **pick a subset** (multiSelect over the ticket keys). Only selected tickets proceed — unselected ones are not analyzed, not transitioned, not fixed. The selection defines "this round" for the round record and Phase 2.

### Step 2: Clean the workspace

For **each of the 4 repos** (`TM-Hiretual-Frontend`, `htm-backend`, `htm-report-engine`, `clickhouse-service`) under the workspace root:

```bash
git -C <repo> status --porcelain
git -C <repo> branch --show-current
```

For a dirty repo, check the current branch first:
- **Current branch already contains `<MAIN_TICKET_ID>`** (it IS the round branch) → do NOT stash. The uncommitted changes are round work in progress — keep them, tell the user they were kept, and skip `pull` for that repo if it would conflict (report instead).
- **Any other branch** → `git -C <repo> stash push -u -m "jira-batch-bug-fix auto-stash $(date +%F)"`. Tell the user which repos were stashed (so they can `git stash pop` later).

Never discard changes.

### Step 3: Check out the main ticket's branches

For each repo:

```bash
git -C <repo> fetch --prune
git -C <repo> branch -r | grep -i "<MAIN_TICKET_ID>"
```

Branch naming is `username/from-branch/<TICKET-ID>`. For every repo where a matching branch exists, check out the branch and pull latest:

```bash
git -C <repo> checkout <branch> && git -C <repo> pull
```

If several branches match in one repo, pick the most recently committed (`git for-each-ref --sort=-committerdate`) and tell the user which one was chosen. Repos with no matching branch are skipped (report them).

If, during analysis (Step 4), a bug's fix requires a repo that has **no** main-ticket branch, do not fix it silently on another branch — create a branch `<username>/from-master/<MAIN_TICKET_ID>` off latest `master` in that repo, and mention this in the hand-off report. A single ticket may touch multiple repos; each repo's change is committed on that repo's checked-out round branch.

### Step 4: Analyze each bug ticket (one at a time)

For each **selected** ticket, in key order:

1. Fetch full detail: `getJiraIssue` with `fields: ["*all"]` (description, comments, attachments).
2. **Images**: each entry in the issue's `attachment` field has an `id`, `filename`, and `mimeType`. Download every image attachment via the Jira REST API (NOT the MCP server, NOT browser screenshots) to the scratchpad:

   ```bash
   curl -sfL -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
     "https://<site>.atlassian.net/rest/api/3/attachment/content/<attachment-id>" \
     -o "<scratchpad>/<TICKET-ID>-<filename>"
   ```

   (`-L` is required — the endpoint replies with a 303 redirect to the media store.) Verify each file is a real image (`file <path>`), then read every one with the Read tool — screenshots usually carry the real repro info. If a download fails, report which attachment could not be fetched instead of silently skipping; the description's embedded media references match attachment filenames/IDs, so keep the mapping per ticket.
3. Locate the buggy code (use the `shared-docs/` knowledge base two-hop lookup, e.g. `features/custom-report/request-chain-overview.md` for Custom Report bugs).
4. Write the analysis doc **before fixing**, in English, at:

```
shared-docs/bug_fix/<TICKET-ID>.md
```

Template:

```markdown
# <TICKET-ID>: <summary>

## Verdict
BUG | NOT-A-BUG (works as designed / feature request / cannot reproduce / data-environment issue) — with reasoning.

## Problem
What the bug is, repro steps, expected vs actual (from ticket description + images).

## Root Cause
File/function references (path:line) and why it misbehaves. For NOT-A-BUG: what the code actually does and why the reported behavior is expected.

## Fix Plan
Concrete change list per service. For NOT-A-BUG: leave empty until the user decides.
```

### Step 4b: Not-a-bug review gate

Not every labeled ticket is a real code bug. If analysis concludes a ticket is **NOT-A-BUG** (behavior matches the intended design, it's actually a feature/change request, it cannot be reproduced, or it's caused by test data/environment), do not silently fix or silently skip it. After all analyses are done, present every NOT-A-BUG candidate to the user — ticket key, one-paragraph judgment with evidence (code refs / screenshots) — and use **AskUserQuestion** per candidate (or one multiSelect) to let the user decide:
- **Fix anyway** → treat as a bug; user's expected behavior becomes the Fix Plan; ticket stays in the round.
- **Drop from round** → no transition, no code change; record it in the round record under "excluded (not a bug)" and list it in the hand-off report so the user can comment/close the ticket in Jira themselves.

Only tickets confirmed as bugs (or "fix anyway") proceed to Step 5.

### Step 5: Transition all tickets, then fix in parallel

**5a — Transition first.** After ALL analysis docs are written and the Step 4b review gate is settled, transition every remaining ticket to **DEV IN PROGRESS**: `getTransitionsForJiraIssue` → find the transition whose target status is `DEV IN PROGRESS` → `transitionJiraIssue`. All transitions happen before any code change starts.

**5b — Group by file overlap.** Read the Fix Plans: tickets whose planned changes touch the **same files** must not run concurrently — put them in sequential order within one group. Non-overlapping tickets form the parallel set.

**5c — Dispatch one subagent per ticket** (all non-overlapping agents in a single message so they run concurrently). Each agent's prompt must contain:
- the ticket ID and the absolute path of its analysis doc (`shared-docs/bug_fix/<TICKET-ID>.md`) — the doc is the spec, follow its Fix Plan
- the repo(s) and already-checked-out branch(es) to work in (agents must NOT switch branches, stash, pull, or touch other repos)
- instructions: implement the fix + ship/adjust tests; run ESLint on every changed TS file (`npx eslint <files>`) / relevant Gradle build for Java and fix all errors; do **NOT** commit, push, or call any Jira tool
- required return value: list of changed file paths per repo, one-line fix summary, ESLint/test result

**5d — Main agent commits, per ticket, sequentially.** After each agent returns, review its diff, then stage **only that ticket's files** and commit on the repo's round branch. The commit message uses the **MAIN ticket ID, not the bug ticket ID**:

```
<MAIN_TICKET_ID> Fix <bug-ticket-id> <imperative description> [ez-ai-assisted]
```

e.g. `HT5-42210 Fix HT5-42661 include sub stage name in stage movement CSV export [ez-ai-assisted]` — no colon after the ticket ID, **never** any AI co-author trailer. If two agents unexpectedly touched the same file, resolve manually before committing and note it in the hand-off report.

htm-backend specifics (per CLAUDE.md): every commit there uses `git commit --no-verify` (the husky pre-commit Jest run times out) — which means YOU must have run ESLint to zero errors before committing; and `nvm use 18.12.1` before pushing (pre-push build hook).

Analysis docs live in `shared-docs/bug_fix/` — if `shared-docs` is itself a git repo, commit them there with the same message format (main ticket ID prefix); otherwise just leave the files on disk.

### Step 6: One PR per repo to develop

After all tickets touching a repo are fixed, check for conflicts against the target branch **before** creating the PR:

```bash
git fetch origin develop
git merge --no-commit --no-ff origin/develop   # dry-run on the round branch
```

**No conflicts** → `git merge --abort` (or keep the merge if develop moved significantly), then push and PR the round branch directly:

```bash
git push -u origin <round-branch>
gh pr create --base develop --title "<MAIN_TICKET_ID> Fix <label> bugs" --body "..."
```

**Conflicts** → do NOT resolve them on the round branch. Cut a temporary merge branch off the target branch, merge the round branch into it, resolve there, and PR the temp branch instead:

```bash
git merge --abort
git checkout -b <username>/from-develop/<MAIN_TICKET_ID>-merge origin/develop
git merge <round-branch>
# resolve conflicts, git add the resolved files, then:
git commit -m "<MAIN_TICKET_ID> Merge <round-branch> into develop [ez-ai-assisted]"
git push -u origin <username>/from-develop/<MAIN_TICKET_ID>-merge
gh pr create --base develop --title "<MAIN_TICKET_ID> Fix <label> bugs" --body "..."
```

(htm-backend: the merge commit also takes `--no-verify`, like all its commits.) Re-run ESLint/build on the merged result before pushing (conflict resolution can break lint). State every conflict you resolved (file + how) in the PR body and the hand-off report, then switch the repo back to the round branch so a later resume still finds it checked out.

PR body must list every fixed ticket (key + one-line fix summary) and a test plan. Do NOT add any AI attribution trailer to commits or the PR body — hireEZ standards use the `[ez-ai-assisted]` commit marker only.

### Step 7: Record the round, STOP, and hand off

Write/update the round record `shared-docs/bug_fix/_round-<MAIN_TICKET_ID>.md`: label used, date, per-repo branch + PR link, the list of fixed ticket IDs, and any tickets excluded as not-a-bug (with the user's decision). Phase 2 reads this file, so it must be accurate even if Phase 2 runs in a fresh session.

Report to the user:
- tickets fixed (now in DEV IN PROGRESS), tickets skipped and why
- PR links per repo
- stashed repos reminder

Then **end the task**. Do NOT transition tickets further. Wait for the user's test feedback.

## Phase 2 — Tests passed

Triggered when the user says the tests passed (e.g. "测试通过"). Load the ticket list from `shared-docs/bug_fix/_round-<MAIN_TICKET_ID>.md` (ask the user for the main ticket ID if unclear which round). For **every ticket fixed in that round**:

1. `getTransitionsForJiraIssue` → find transition to **TEST SERVER(VERIFYING)**.
2. `transitionJiraIssue`.
3. Report the final status of each ticket.

If a ticket has no direct transition to that status, list its available transitions and ask the user instead of guessing a multi-hop path.

## Rules / Red flags

| Temptation | Reality |
|---|---|
| "Fix first, write the doc later" | Analysis doc in `shared-docs/bug_fix/` comes BEFORE the code change. |
| "Skip stash, changes look unrelated" | Stash every dirty repo unless its current branch is already the main-ticket round branch — that one exception only. |
| "Dirty on the round branch, stash to be safe" | Don't. Changes on the round branch are in-progress round work; stashing hides them from commits. Keep and report. |
| "Batch-transition to VERIFYING right after PR" | Phase 2 only happens after explicit user confirmation of test results. |
| "Skip ESLint, tsc passed" | ESLint-only rules block CI. Run it on every changed TS file. |
| "Add Co-Authored-By: Claude" | Forbidden. `[ez-ai-assisted]` marker only. |
| "Prefix the commit with the bug ticket ID" | Commits are tracked under the MAIN ticket: `<MAIN_TICKET_ID> Fix <bug-id> ...`. The bug ID goes in the description, never as the prefix. |
| "Image won't download, ignore it" | Screenshots carry the repro. Fix the REST download (credentials, `-L`, attachment id) or report the failure — never analyze blind. |
| "MCP can't fetch the image, screenshot the browser instead" | Browser screenshots mis-capture and mix pages. Always use the Jira REST attachment endpoint with `$JIRA_API_TOKEN`. |
| "Let each subagent commit its own change" | Agents only edit and report. The main agent stages per-ticket files and commits sequentially — parallel commits on one branch corrupt the round. |
| "Fix tickets one by one, parallel is risky" | Analysis already serialized the risk: overlapping-file tickets run sequentially, the rest MUST run as parallel subagents in one message. |
| "Skip the scope question, user said fix the label" | Always ask all-or-subset after listing tickets. The user may want a partial round. |
| "Looks like intended behavior, just skip it" / "ticket says bug, so fix it" | Neither. A NOT-A-BUG verdict goes through the Step 4b gate: summarize the evidence and let the USER decide fix-anyway vs drop. |
| "MCP tools missing, improvise via curl for everything" | REST is for attachment download only. Jira search/read/transition must go through the Atlassian MCP — run Step 0 preflight and get it connected first. |
