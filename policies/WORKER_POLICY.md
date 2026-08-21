# WORKER_POLICY

**Version:** 0.1
**Status:** Initial governance rules
**Authority:** Subordinate to `docs\AI_ORCHESTRA_GUIDELINES.md`.

This document defines the authorized capabilities and restrictions of worker agents within the AI_ORCHESTRA ecosystem.

---

## 1. Principles

1. A worker agent is an execution-oriented entity.
2. A worker operates only within the boundaries set by the orchestrator and the task contract.
3. Any action not explicitly permitted is forbidden.

---

## 2. Permitted Actions

A worker agent is authorized to perform the following operations:

1. **Read Assigned Worktree:** Inspect files and history within its designated task worktree.
2. **Modify Authorized Paths:** Edit, create, or delete files only within the `allowed_paths` defined by the task contract.
3. **Run Development Commands:** Execute authorized build, compilation, or linting commands required to complete the task.
4. **Run Tests:** Run the test suite or test commands within the worktree to verify the changes.
5. **Return Structured Reports:** Produce a structured result artifact (conforming to `WORKER_REPORT.schema.json`) detailing files modified, test results, and status.

---

## 3. Forbidden Actions

A worker agent must not perform, request, or initiate any of the following operations:

1. **Push:** Push changes directly to any remote repository.
2. **Merge:** Merge branches or perform pull request merges.
3. **Force Push:** Execute any force-push operations (`git push --force` or similar).
4. **Change Credentials:** Modify, create, or read host credentials, SSH keys, or configuration.
5. **Change Secrets:** Access, write, or alter environment secrets, `.env` files, API keys, or tokens.
6. **Expand Scope:** Modify files outside the authorized `allowed_paths` or touch paths in `forbidden_paths`.
7. **Self-Authorize Extra Iterations:** Request or grant itself additional attempts, calls, or correction rounds beyond those allocated by the Supervisor.
