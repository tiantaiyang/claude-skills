---
name: ticket-docs-publish
description: "Use when the user gives a Jira ticket id and wants every repo the ticket touches to get its own spec + plan written and published to Confluence — e.g. \"/ticket-docs-publish HT5-45803\", \"给 HT5-45803 涉及的仓库都创建文档并发布\", \"找到这个 ticket 相关的所有仓库，调用 ez-spec / ez-plan / ez-publish\", \"write and publish spec and plan for every repo in HT5-12345\". Finds the repos from local branches, commits and the ticket text, skips the default-excluded repos (databases, ez-conversation-agent, ez-agent-kit, ez-a2ui), runs one subagent per repo (ez-spec → ez-plan → ez-publish dry-run), then publishes in a staggered order so the shared Confluence ticket page is created exactly once."
---

# Ticket docs publish (one ticket → spec + plan + Confluence for every repo it touches)

Given one Jira ticket id, find every repo in the workspace that the ticket touches, and for each
repo (minus the excluded ones) run **one subagent inside that repo** that calls
`/ez-spec` → `/ez-plan` → `/ez-publish`. All docs land under one Confluence ticket page:

```
HPD › Releases (3701473281)
 └─ release/MMDDYYYY                         L1  (ticket fixVersion name)
     └─ <TICKET-ID> - <ticket summary>       L2  (ONE page, shared by every repo)
         ├─ [<TICKET-ID>][<dev_id>][<repo>] - Spec    L3
         └─ [<TICKET-ID>][<dev_id>][<repo>] - Plan    L3
```

Requires the `ez-engineering` plugin (`ez-engineering:ez-spec`, `ez-engineering:ez-plan`,
`ez-engineering:ez-publish`) and the Atlassian MCP (`getJiraIssue`, `searchConfluenceUsingCql`).

## Invocation

```
/ticket-docs-publish <TICKET-ID>
/ticket-docs-publish <TICKET-ID> 除了 <repo> <repo>      → add exclusions
/ticket-docs-publish <TICKET-ID> 包括 databases          → drop a default exclusion
/ticket-docs-publish <TICKET-ID> 只要 <repo> <repo>      → restrict to these repos
```

**Default exclusions** (not documented/published unless the user explicitly includes them):
`databases`, `ez-conversation-agent`, `ez-agent-kit`, `ez-a2ui`.

Invoking this skill is the user's authorization to write `.ez-ai/` files in each repo and to
create/update Confluence pages for this ticket. It is **not** authorization to switch branches,
commit, push, stash, or touch source code in any repo — no step of this skill does that.

## Step 0 — Preflight

- Workspace root = the current directory if it holds several git repos (e.g. `~/tyre/native`);
  otherwise ask for it.
- The three `ez-engineering:*` skills appear in the skill list, and the Atlassian MCP tools load
  (`ToolSearch select:mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchConfluenceUsingCql`).
  If either is missing, stop and tell the user what to install/connect.
- `git config user.email` is set (ez-publish derives `{dev_id}` from it).

## Step 1 — Read the ticket

`getJiraIssue` (cloudId `hiretual.atlassian.net`, `responseContentFormat: markdown`), then a
second call with `fields: ["fixVersions","duedate","parent","issuetype"]`. Keep: summary,
description, fixVersions (name + releaseDate), duedate, `issuetype.subtask`, parent key/summary.

## Step 2 — Find the repos

```bash
T=<TICKET-ID>
cd <workspace-root>
for d in */; do d=${d%/}; [ -e "$d/.git" ] || continue
  br=$(git -C "$d" branch -a --list "*$T*" --format='%(refname:short)' | head -6 | tr '\n' ' ')
  n=$(git -C "$d" log --all --oneline --grep="$T" | wc -l | tr -d ' ')
  cur=$(git -C "$d" branch --show-current)
  dirty=$(git -C "$d" status --porcelain | wc -l | tr -d ' ')
  if [ -n "$br" ] || [ "$n" -gt 0 ]; then echo "$d | cur=$cur | branches=$br | commits=$n | dirty=$dirty"; fi
done
```

A repo is **in scope** if it has a branch or commit carrying the ticket id, **or** the ticket
description names it (match workspace directory names against the description text, including a
"Repos and branches" section if present). Then apply exclusions. Skip `.wt/` worktrees and
`_*` backup dirs.

For each in-scope repo record:

- **Ticket branch** — prefer the current branch if it carries the id; else, in order: `<T>`,
  `*/from-master/<T>`, `*/from-develop/<T>`, `*/develop/<T>`. Ignore `-merge`, `-rN`, `backup/*`
  and `*/from-<T>/<OTHER>` (sub-ticket) branches.
- **Diff base** — `origin/master` for `from-master` branches, else `origin/develop`. Agents must
  confirm with `git merge-base`; when the branch is already fully merged (merge-base == tip), use
  the parent of the first ticket commit instead.
- **Slice** — the ticket-description sections/bullets that name this repo. If none do, the slice
  is "derive it from the branch commits".
- **Dirty tree** — non-zero `dirty` means someone's uncommitted work: the agent must leave it alone.
- **Publish config state** — `grep -c 'publish' <repo>/.ez-ai/config.yaml` (none / no block /
  block present, and whether `repo_name` is set).

Print the repo table (repo, branch, base, slice, dirty, config state) and proceed — do not wait
for confirmation unless no repo was found or a repo name in the request matches nothing.

## Step 3 — Pin the Confluence hierarchy once (for every agent)

Repos disagree on `release_folder.source` (`ticket_duedate`, `fix_version`, …) and a ticket with
no duedate would fall through to a manual prompt in each agent. Resolve it **once** here and hand
the answer to every agent:

1. **L1** — the ticket's fixVersion **name** when it is folder-shaped (`release/MMDDYYYY`); else
   the duedate as `release/MMDDYYYY`; else ask the user. For a **subtask**, use the parent's
   fixVersion/duedate (ez-publish then nests L2 = parent, L2s = subtask on its own).
   Do NOT use fixVersion `releaseDate` — names and dates often differ by a day.
2. **L2 title** — `<TICKET-ID> - <ticket summary>`.
3. Look both up:

   ```
   space = HPD AND type = page AND (title = "<L1>" OR title ~ "<TICKET-ID>")
   ```

   Record the L1 page id (it usually exists already) and whether L2 already exists (its id).

## Step 4 — Phase 1: one agent per repo, in parallel

Launch all agents in **one message** (`subagent_type: general-purpose`, background). Fill the
template below per repo. Keep each agent's id → repo mapping; you'll message them in phase 2.

```text
You own the repo `<REPO>` for Jira ticket <TICKET-ID>. Work only inside
`<WORKSPACE>/<REPO>` (cd there first; ticket branch `<BRANCH>`, diff base <BASE> — confirm with
merge-base; if the branch is already fully merged, use the parent of the first ticket commit).
The user asked for: /ez-spec → /ez-plan → /ez-publish for this repo. You run phase 1 now;
publishing comes in phase 2 when I message you.

Ground rules: do NOT switch branches, commit, push, stash, or modify source code.<IF current
branch != ticket branch: The working tree is on `<CUR>`, not the ticket branch — read the
ticket branch with `git log/diff/show <BRANCH>`, never check it out.><IF dirty: This tree has
<N> uncommitted changes belonging to someone else — leave them exactly as they are.> The only
files you may write are under `.ez-ai/`. There is no human to answer questions — wherever a
skill would ask the user, decide from evidence (ticket, commits, code, docs) and record the
assumption / open question in the doc instead of blocking.

Context:
- Ticket: fetch with getJiraIssue (cloudId `hiretual.atlassian.net`, key <TICKET-ID>,
  markdown): "<SUMMARY>". This repo's slice: <SLICE>.
- Evidence: `git log --oneline --grep=<TICKET-ID> <BRANCH>`, `git log <BASE>..<BRANCH>`, the
  diff; repo AGENTS.md/CLAUDE.md; <any workspace docs about the ticket, e.g. docs/specs/*<TICKET-ID>*>.
  Write the spec/plan for THIS repo's slice (other repos are upstream/downstream touchpoints),
  describing the change as built plus remaining work/risks, grounded in real file paths. Keep
  the docs proportionate — a one-file change gets a short doc.

Phase 1 steps:
1. Invoke the Skill `ez-engineering:ez-spec` with args `<TICKET-ID>` → `.ez-ai/sessions/<TICKET-ID>/spec.md`.
2. Invoke the Skill `ez-engineering:ez-plan` with args `<TICKET-ID>` → `.ez-ai/sessions/<TICKET-ID>/plan.md`.
3. Make sure `.ez-ai/config.yaml` has a working `publish.confluence` block with
   `repo_name: "<REPO>"`. <CONFIG STATE: "missing file → create it with only the block below" |
   "no publish block → append the block below" | "block present → only fix what's wrong
   (enabled, repo_name, {dev_id} titles) and drop any obsolete publish.jira block">. Touch no
   other section. Block:
   <PASTE THE PUBLISH BLOCK FROM "Publish config block" BELOW, repo_name filled in>
4. Invoke the Skill `ez-engineering:ez-publish` with args `<TICKET-ID> --dry-run`. Pinned
   hierarchy (the user's decision — use it as the manual answer): L1 = `<L1>` (page <L1_ID>);
   L2 title = `<L2_TITLE>` (<"exists, page <L2_ID>" | "may not exist yet">).
5. STOP. Do not run a real publish. Final report (concise): spec/plan paths, 3–5 line summary,
   config.yaml change, the dry-run page plan, open questions/assumptions.

Phase 2 (only when I message you): run `ez-engineering:ez-publish` with args
`<TICKET-ID> --yes` with the same pinned hierarchy. Find-or-create: look up your L3 titles by
exact title AND among L2's children (search lags) before creating; reuse the existing L2 —
never create a second one. Verify each page carries the Jira inlineCard and that its tail
survived the round-trip. Report the L3 URLs.
```

### Publish config block

```yaml
publish:
  confluence:
    enabled: true
    space: "HPD"
    parent_page_id: "3701473281"            # L0: the "Releases" page
    auth: "mcp"
    repo_name: "<REPO>"                      # required: worktree dir names break {repo}
    default_include: ["*.md"]
    default_title_pattern: "[{ticket_id}][{dev_id}][{repo}] - {doc_type}"
    release_folder:
      source: fix_version_name               # fixVersion NAME, e.g. release/10222026
      format: "release/MMDDYYYY"
    ticket_parent_title_pattern: "{ticket_id} - {ticket_title}"
    rules:
      - source: spec.md
        title_pattern: "[{ticket_id}][{dev_id}][{repo}] - Spec"
        update_existing: true
      - source: plan.md
        title_pattern: "[{ticket_id}][{dev_id}][{repo}] - Plan"
        update_existing: true
      - source: elaboration.md
        title_pattern: "[{ticket_id}][{dev_id}][{repo}] - Elaboration"
        update_existing: true
```

## Step 5 — Phase 2: staggered publish (L2 created exactly once)

Concurrent ez-publish runs that all find "no L2" will each create one. So:

- **L2 does not exist yet:** when the **first** agent reports phase 1 done, send it phase 2
  alone, telling it to re-check (exact title + L1's children) and create L2 only if still absent.
  Get the L2 page id from Confluence (CQL by title) as soon as it appears.
- **L2 exists** (from Step 3, or created above): every other agent gets phase 2 the moment it
  reports phase 1 done:

  ```text
  Phase 2: run `ez-engineering:ez-publish` with args `<TICKET-ID> --yes` now. Reuse L1 <L1_ID>
  and the existing L2 <L2_ID> — do not create any L2. Check by exact title (and L2's children)
  for existing <REPO> L3 pages first and update in place if present. Report the L3 page URLs.
  ```

Don't wait for all of phase 1 to finish before starting phase 2 — publish as agents arrive.

## Step 6 — Recover from interrupted agents

Agents die mid-run on API errors (429 rate limit / spend limit). When the user says the quota is
back (or the error was transient):

1. List what already exists: `space = HPD AND type = page AND (parent = <L2_ID> OR title ~ "<TICKET-ID>")`,
   and per repo `wc -l .ez-ai/sessions/<TICKET-ID>/{spec,plan}.md` + `.ez-ai/.audit/ez-publish-runs/`.
2. Resume **each** agent with SendMessage (its transcript is intact) — never start a fresh agent
   for a repo that already has one. Tell it exactly where it was and which of its pages already
   exist (page ids), and that publishing is idempotent by exact title: update in place, never
   create duplicates, make sure each page carries the Jira inlineCard.
3. Agents still in phase 1 may go straight on to phase 2 once L2 exists — say so in the resume
   message to save a round trip.

## Step 7 — Verify, then report

```
space = HPD AND type = page AND (parent = <L2_ID> OR title ~ "<TICKET-ID>") ORDER BY title
```

- Exactly one L2; exactly one Spec + one Plan per repo (2 × repos L3 pages, plus any
  Elaboration); no `… (2)` titles; every L3 summary starts with `Jira ticket:` (the inlineCard).
- `git -C <repo> status --porcelain | grep .ez-ai` per repo, to list config files changed or
  created (tracked `M .ez-ai/config.yaml` vs untracked `?? .ez-ai/`). Nothing is committed.

Report to the user:

1. The L2 link and a table: repo | Spec link | Plan link.
2. The repos excluded and why (default list / user request); repos found but skipped.
3. Working-tree changes per repo (they decide whether to commit them).
4. Notable findings the agents surfaced — things that contradict memory or docs, commits that
   belong to another ticket, unverified test-env items, decisions awaiting sign-off. Skip routine
   per-repo detail.

## Rules / Red flags

| Temptation | Reality |
|---|---|
| "Let every agent publish as soon as it's ready" | First publisher alone creates L2; parallel creators make duplicate ticket pages. |
| "Each repo's config picks its own release folder" | Pin L1 once. A ticket without duedate makes `ticket_duedate` repos prompt or diverge. |
| "Use fixVersion releaseDate for the folder" | Use the fixVersion **name**; the date often sits a day later (`release/10232026` ≠ `release/10222026`). |
| "Agent can't ask the user, so it should stop" | It records assumptions/open questions in the doc and continues. |
| "Checkout the ticket branch to read the code" | Never switch branches — read it via `git show <branch>:<path>`. |
| "Commit the .ez-ai config so it's clean" | No commits. Report the changes; the user decides. |
| "Agent died on 429, launch a new one" | Resume the same agent with SendMessage; a fresh one redoes the work and may duplicate pages. |
| "Search found no L3, create it" | Search lags minutes. Also list L2's children before creating. |
| "Excluded repo has the most commits, include it anyway" | Exclusions are the user's call: default list unless they say otherwise. |
| "Spin up a team / workflow for this" | One general-purpose agent per repo via the Agent tool is the whole fan-out. |
