# claude-skills

Reusable [Claude Code](https://claude.com/claude-code) skills.

## Skills

| Skill | What it does |
|---|---|
| [`commit-pr`](skills/commit-pr/SKILL.md) | Commit the current branch in **one** repo, push it, and open a PR. Default target is `develop`. Merge direction is one-way: conflicts are resolved on a temp branch cut from the target — the working branch never receives the target's history. |
| [`jira-batch-bug-fix`](skills/jira-batch-bug-fix/SKILL.md) | Batch-analyze and fix Jira bugs found by a label under a main ticket: cleans the workspace, checks out the main ticket's branches, writes a per-ticket analysis doc, fixes bugs in parallel with one subagent per ticket, opens PRs to `develop`, and handles the two-phase Jira status transitions (`DEV IN PROGRESS` → `TEST SERVER(VERIFYING)`). |
| [`ticket-docs-publish`](skills/ticket-docs-publish/SKILL.md) | Give it a Jira ticket id: finds every workspace repo the ticket touches (branches, commits, ticket text), skips the default-excluded repos, runs one subagent per repo that calls `/ez-spec` → `/ez-plan` → `/ez-publish`, and publishes all Spec/Plan pages under one shared Confluence ticket page (staggered so it is created exactly once). |

## Install

### Option 1 — one-line script (simplest)

Install only `commit-pr` (Claude Code `~/.claude/skills/`; also Cursor `~/.cursor/skills/` if Cursor is installed):

```bash
curl -fsSL https://github.com/tiantaiyang/claude-skills/raw/refs/heads/main/install.sh | bash -s commit-pr
```

Install every skill:

```bash
curl -fsSL https://github.com/tiantaiyang/claude-skills/raw/refs/heads/main/install.sh | bash
```

Cursor only: append `--cursor`. Custom dest: `--dest DIR`. Re-run the same command any time to update, then restart Claude Code / Cursor.

### Option 2 — Claude Code plugin

Inside Claude Code. This marketplace plugin ships **every** skill in this repo:

```
/plugin marketplace add tiantaiyang/claude-skills
/plugin install jira-batch-bug-fix@tiantaiyang-skills
```

Plugins update via `/plugin` → manage.

---

## commit-pr

Commit whatever is in one repo's working tree, push the current branch, and open a PR. Requires `gh` authenticated (`gh auth login`).

```
/commit-pr <repo>                        → PR to develop
/commit-pr <repo> 到 master 分支          → PR to master
/commit-pr <repo> to <branch>            → PR to <branch>
```

e.g. `/commit-pr ez-report-agent` or `/commit-pr htm-backend 到 master 分支`

---

## jira-batch-bug-fix

### Prerequisites

- **Atlassian MCP server** connected in Claude Code (Jira read/transition goes through it). The skill checks this on startup and walks you through connecting if missing:

  ```bash
  claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse
  ```

  then complete the OAuth authorization in your browser on first use.
- **Jira REST credentials** for attachment (screenshot) download, in your shell profile:

  ```bash
  export JIRA_EMAIL="you@example.com"
  export JIRA_API_TOKEN="<token from https://id.atlassian.com/manage-profile/security/api-tokens>"
  ```

- `gh` CLI authenticated (PR creation).

### Usage

```
/jira-batch-bug-fix label <your-label> 主ticket <MAIN-TICKET-ID>
```

e.g. `/jira-batch-bug-fix label bug_0730_customreport 主ticket HT5-42210`

After your testing passes, tell Claude "测试通过" (tests passed) to trigger phase 2 (bulk transition to TEST SERVER(VERIFYING)).

---

## ticket-docs-publish

### Prerequisites

- The `ez-engineering` plugin (`ez-spec`, `ez-plan`, `ez-publish` skills).
- Atlassian MCP connected (Jira read + Confluence read/write).
- Run it from the workspace root that holds the repos (e.g. `~/tyre/native`).

### Usage

```
/ticket-docs-publish <TICKET-ID>
/ticket-docs-publish <TICKET-ID> 除了 <repo> <repo>      → add exclusions
/ticket-docs-publish <TICKET-ID> 包括 databases          → drop a default exclusion
/ticket-docs-publish <TICKET-ID> 只要 <repo> <repo>      → restrict to these repos
```

Default exclusions: `databases`, `ez-conversation-agent`, `ez-agent-kit`, `ez-a2ui`.

Pages land at `HPD › Releases › release/MMDDYYYY (ticket fixVersion name) › <TICKET-ID> - <summary> › [<TICKET-ID>][<dev_id>][<repo>] - Spec | Plan`.
Each repo's `.ez-ai/config.yaml` publish block is created or fixed when needed; nothing is committed.
