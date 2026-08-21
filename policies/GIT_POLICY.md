# GIT_POLICY

**Version:** 0.1
**Status:** Initial governance rules
**Authority:** Subordinate to `docs\AI_ORCHESTRA_GUIDELINES.md`.

This document defines the git and GitHub commands authorized during execution, as well as the rules governing branches and repositories.

---

## 1. Protected Branches

1. The list of protected branches must be retrieved dynamically from `config\PROJECT_STATE.json` (for example: `["main"]`).
2. Protected branches are guarded against direct writes, force pushes, and automated merges.

---

## 2. Allowed Operations

The following Git and GitHub CLI operations are authorized for execution by the orchestrator:

1. `git status` — inspect repository status and untracked files.
2. `git diff` — analyze staged and unstaged file differences.
3. `git add` — stage authorized changes.
4. `git commit` — commit staged changes with a descriptive message.
5. `git push <authorized task branch>` — push commits to the remote task branch assigned to the run.
6. `gh pr create` — create a pull request from the task branch to the default branch.
7. `gh pr edit` — update pull request metadata or description.

---

## 3. Forbidden Operations

The following operations are strictly prohibited under any circumstances:

1. `git push --force` — force pushing commits to any remote branch.
2. **Direct Push to Protected Branches** — pushing directly to `main`, `master`, or any branch listed in `PROJECT_STATE.json`.
3. **Automatic Merge** — merging branches or pull requests automatically without human authorization.
4. **Remote Protected-Branch Deletion** — deleting a remote protected branch.
5. **Secret Modification** — staging or pushing files containing credentials, tokens, or private environment configurations.
6. **Repository Permission Modification** — modifying branch protection rules, deploy keys, or repository access policies.
