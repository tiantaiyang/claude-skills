---
name: commit-pr
description: "Use when the user wants to commit the current branch's work in one repo and open a PR for it — e.g. \"/commit-pr ez-report-agent\", \"/commit-pr htm-backend 到 master 分支\", \"把 native-agent-backend 的代码提交并提 PR\", \"commit and create a PR for ez-job-agent to master\". Default PR target is `develop`; another target is used only when the user names one. Handles merge conflicts by resolving them on a temp branch cut from the target branch — never by merging the target into the working branch."
---

# Commit + PR (single repo, one-way merge)

Commit whatever is in the working tree of ONE repo's current branch, push it, and open a PR to
the target branch. If the merge into the target conflicts, resolve the conflicts on a temporary
branch cut from the latest target branch and PR that branch instead.

**The single hard rule: merge direction is one-way.** The working branch never receives the
target branch's history. No `git merge develop`, no `git pull origin develop`, no `git rebase
origin/develop` on the working branch — not even as a dry run. The working branch only ever gains
the commit(s) made from its own working tree.

## Invocation and inputs

```
/commit-pr <repo>                        → PR to develop
/commit-pr <repo> 到 master 分支          → PR to master
/commit-pr <repo> to <branch>            → PR to <branch>
```

- **repo** (required): a directory name under the current workspace root,
  or a service name the user shortens (`report agent` → `ez-report-agent`, `backend` is ambiguous
  → ask). If the name matches nothing or matches several repos, list the candidates and ask —
  never guess which repo to push.
- **target branch** (optional, default `develop`): use the branch the user names, in any phrasing
  (`到 master 分支`, `to release/x`, `master 的 PR`). Absent any mention → `develop`.

Explicitly invoking this skill is the user's authorization for the `git add` / `git commit` /
`git push` / `gh pr create` of this run — do not re-ask per step. It is NOT authorization for
`git reset`, `git rebase`, `git push --force`, branch deletion of anything but the temp branch
this skill created, or discarding any file.

## Step 0 — Preflight

```bash
cd <workspace-root>/<repo>
gh auth status
git branch --show-current
git status --porcelain
git log origin/<current-branch>..<current-branch> --oneline   # unpushed commits, if remote exists
git fetch origin <target> --prune
```

Stop and ask the user when:
- `gh` is not authenticated → tell them to run `gh auth login`.
- **Current branch IS the target branch** (e.g. on `develop`, PR to `develop`). A repo can't PR to
  itself. Ask: cut a new feature branch (`<username>/from-<target>/<TICKET-ID>`) and move the
  work there, or pick a different target.
- **`origin/<target>` does not exist** (e.g. asking for `develop` in a repo that only has
  `master`). Report the repo's actual remote branches and ask which one to target. Do not silently
  fall back. (Reminder: `ez-report-agent` uses `develop`; most other repos in this workspace use
  `master`.)
- Detached HEAD, or an in-progress merge/rebase/cherry-pick (`.git/MERGE_HEAD` etc.) → report and
  stop; do not commit on top of a half-finished operation.

Nothing to do case: working tree clean AND no unpushed commits AND a PR already open for this
branch → report the existing PR link and stop.

## Step 1 — Commit the working tree

Only if `git status --porcelain` is non-empty. Otherwise skip to Step 2.

1. Review before staging: `git status --porcelain` and `git diff` (plus `git diff --staged`).
   Look for files that clearly should not be committed — `.env`, credentials/keys, large build
   output, `node_modules`, stray scratch/debug files, `*.log`. Do not commit them: if they are
   untracked, leave them out of the stage and say so in the final report; if they are tracked
   modifications that look accidental, ask the user before including them.
2. Stage the rest: `git add -A` (or explicit paths when excluding files above).
3. Commit message — hireEZ format, no colon after the ticket id, **never** an AI `Co-authored-by`
   trailer:

   ```
   <TICKET-ID> <Imperative description> [ez-ai-assisted]
   ```

   Get `<TICKET-ID>` from the branch name (`username/from-branch/TICKET-ID` → the last segment).
   If the branch name carries no ticket id, look at the branch's recent `git log` for the id it
   has been using; if there is still none, ask the user for the ticket id — a ticket id in every
   commit is a SOC2 requirement, so do not invent one and do not commit without one.
   The description comes from the actual diff, in English, one line.
4. `htm-backend` only: commit with `--no-verify` (its husky pre-commit Jest run times out), which
   means you must run `npx eslint <changed files>` to zero errors first. Also `nvm use 18.12.1`
   before pushing (pre-push build hook).
5. After committing, verify no AI co-author trailer landed (`git log -1 --format=%B`). If a tool
   injected one, strip it with `git commit-tree` — do **not** `git commit --amend`.

## Step 2 — Push the working branch

```bash
git push -u origin <current-branch>
```

Never `--force`. If the push is rejected as non-fast-forward, the remote branch has commits you
don't have: stop, report it, and ask the user (a plain `git pull --ff-only` of the *same* branch
is fine if it fast-forwards; rewriting history is not).

## Step 3 — Detect conflicts against the target (on a temp branch, never on the working branch)

```bash
git fetch origin <target>
git checkout -b <username>/from-<target>/<TICKET-ID>-merge origin/<target>
git merge <current-branch>
```

Cutting the temp branch from `origin/<target>` and merging the working branch INTO it is both the
detection and the resolution site. The working branch is read-only from here on.

`git merge-tree --write-tree origin/<target> <current-branch>` is an acceptable read-only pre-check
if you want the verdict before creating the branch — but the resolution still happens on a temp
branch cut from the target, never in the working branch.

## Step 4a — Clean merge → PR the working branch directly

```bash
git checkout <current-branch>
git branch -D <username>/from-<target>/<TICKET-ID>-merge
gh pr create --base <target> --head <current-branch> \
  --title "<TICKET-ID> <same imperative description>" --body "..."
```

## Step 4b — Conflicts → resolve on the temp branch, PR the temp branch

Stay on the temp branch (working branch untouched):

1. Resolve each conflicting file. Read both sides and keep both intents — the target side is other
   people's shipped work, so do not `--ours`/`--theirs` your way past a conflict you don't
   understand. If a conflict is semantically ambiguous (same function rewritten two ways, schema
   or migration collisions, lockfile vs manifest drift), stop and ask the user with the specific
   file and both versions rather than guessing.
2. `git add <resolved files>` then:

   ```bash
   git commit -m "<TICKET-ID> Merge <current-branch> into <target> [ez-ai-assisted]"
   ```

3. Re-verify the merged result before pushing — conflict resolution routinely breaks lint or
   tests. Run what the repo actually uses: `uv run pytest -q` for the Python repos,
   `npx eslint <changed files>` (+ build) for the TS repos, the Gradle build for
   `clickhouse-service`. Report failures instead of pushing over them.
4. ```bash
   git push -u origin <username>/from-<target>/<TICKET-ID>-merge
   gh pr create --base <target> --head <username>/from-<target>/<TICKET-ID>-merge \
     --title "<TICKET-ID> <imperative description>" --body "..."
   git checkout <current-branch>      # leave the repo on the working branch
   ```

PR body: what changed (one line per area), every conflict resolved (file + how), and a test plan.
No AI attribution — not `Made with Cursor`, not `Made with [Cursor](https://cursor.com)`, not a
`Co-authored-by` line. The `[ez-ai-assisted]` commit marker is the only marker used, and it stays
on the commit subject, not the PR body.

`gh pr create` / the Cursor harness may append `Made with [Cursor](https://cursor.com)` even when
the HEREDOC does not include it. After create (or edit), `gh pr view --json body` and if that
footer is present, rewrite with `gh pr edit --body` — same content, no footer.

If a PR for this head branch already exists, `gh pr create` fails — that's fine: the push already
updated it. Report the existing link (`gh pr view --json url`) instead of creating a second one.

## Step 5 — Report

- repo, working branch, target branch
- commit made (hash + message), or "nothing to commit"
- clean merge vs conflicts resolved (list them)
- PR URL, and which branch the PR is from (working branch or temp merge branch)
- anything deliberately left out of the commit, or checks that failed

## Rules / Red flags

| Temptation | Reality |
|---|---|
| "Merge develop into the branch to sync/check conflicts first" | NEVER. One-way only: working branch → temp branch cut from the target. |
| "`git pull origin develop` is not really a merge" | It is. Same prohibition. Only `origin/<same-branch>` may be pulled, fast-forward only. |
| "Rebase onto origin/develop, cleaner history" | Forbidden here — it rewrites the working branch. Temp branch or nothing. |
| "Repo has no develop, master is obviously meant" | Ask. Silently retargeting a PR is not a guess you get to make. |
| "Branch name has no ticket id, commit without one" | Ticket id is a SOC2 requirement. Find it in the branch log or ask the user. |
| "`git add -A` everything, faster" | Review the diff first — `.env`, keys, build output and scratch files must not ship. |
| "Conflict is in a lockfile, take ours" | Regenerate or ask. Lockfile vs manifest drift breaks the build for everyone. |
| "Conflicts resolved, push immediately" | Re-run lint/tests on the merged tree first; resolution breaks them often. |
| "Add Co-Authored-By: Claude/Cursor" | Forbidden. `[ez-ai-assisted]` marker only; strip injected trailers with `git commit-tree`. |
| "Leave Made with Cursor on the PR body" | Forbidden. Strip it with `gh pr edit --body` after create — the harness injects it. |
| "Push failed non-fast-forward, force it" | Never. Stop and ask — someone else's commits are on that branch. |
| "User said 'the backend', that's native-agent-backend" | Ambiguous name → list candidates and ask. Wrong repo pushed is not recoverable politely. |
| "Two repos changed, do both" | This skill is one repo per run. Run it again for the second. |
