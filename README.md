# claude-skills

Reusable [Claude Code](https://claude.com/claude-code) skills.

## Skills

| Skill | What it does |
|---|---|
| [`commit-pr`](skills/commit-pr/SKILL.md) | Commit the current branch in **one** repo, push it, and open a PR. Default target is `develop`. Merge direction is one-way: conflicts are resolved on a temp branch cut from the target — the working branch never receives the target's history. |
| [`jira-batch-bug-fix`](skills/jira-batch-bug-fix/SKILL.md) | Batch-analyze and fix Jira bugs found by a label under a main ticket: cleans the workspace, checks out the main ticket's branches, writes a per-ticket analysis doc, fixes bugs in parallel with one subagent per ticket, opens PRs to `develop`, and handles the two-phase Jira status transitions (`DEV IN PROGRESS` → `TEST SERVER(VERIFYING)`). |

## Install

### Option 1 — one-line script (simplest)

Install every skill into `~/.claude/skills/` (overwrites same-named skills):

```bash
curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash
```

Install only `commit-pr` into Claude Code (`~/.claude/skills/`):

```bash
curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash -s commit-pr
```

Install only `commit-pr` into Cursor (`~/.cursor/skills/`):

```bash
curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash -s commit-pr --cursor
```

Re-run the same command any time to update. Restart Claude Code / Cursor afterwards.

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
