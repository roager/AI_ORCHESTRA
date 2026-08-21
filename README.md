# AI_ORCHESTRA

> **Experimental.** This project is in Phase 0 (Foundation). No orchestration logic is implemented yet.
> Autonomous publication and merge are **not enabled**. No agent may push to a protected branch,
> force push, or merge. Every uncertain, sensitive or high-impact decision escalates to a human.

## Purpose

AI_ORCHESTRA is a lightweight, local orchestration system for coordinating AI software-development
agents (initially Codex CLI and Claude Code CLI). It provides a controlled, auditable and
cost-bounded mechanism to define a development task, delegate it to an agent, isolate it in its own
Git worktree, validate the output deterministically, have it independently reviewed, bound the
correction loop, enforce budgets, and publish approved work through Git/GitHub.

It is deliberately **not** a general-purpose agent framework. The objective is *useful autonomy
inside explicit boundaries, with deterministic enforcement and human authority.*

## Architecture Summary

Four roles, deliberately separated:

| Role | Responsibility |
| --- | --- |
| **Human** | Ultimate authority. Approves sensitive decisions, resolves escalations, changes policy. |
| **Codex** | Planner, independent reviewer, publication authority (reasoning only). |
| **Worker Agent** | Claude Code initially. Implements a bounded task inside an isolated worktree. |
| **Supervisor** | Deterministic PowerShell code. Creates workspaces, invokes agents, validates, enforces scope and budgets, records the audit trail. |

Flow:

```text
reasoning → execution → validation → authorization → publication
```

Agents communicate through small structured artifacts on the filesystem
(`TASK.json`, `STATUS.json`, `WORKER_REPORT.json`, `REVIEW.json`, `RESULT.json`), not through
unrestricted conversation. Git is the authoritative source for code changes.

Key invariants: one task / one worktree; no direct push to a protected branch; no force push;
no automatic merge; no unbounded agent loops; `MAX_CORRECTION_ROUNDS = 1`; budgets enforced outside
the agent; every run has an audit trail.

## Current MVP Status

**Phase 0 — Foundation (in progress).**

| Item | Status |
| --- | --- |
| Guidelines | Done |
| Repository structure | Done |
| JSON Schema contracts (`schemas\`) | Done |
| `policies\BUDGET_POLICY.json` | Done (provisional values) |
| Written policies (`ORCHESTRATOR`, `WORKER`, `CODEX`, `GIT`, `SECURITY`, `ESCALATION`) | Not started |
| `config\PROJECT_STATE.json` | Not started |
| Contract tests | Not started |
| Phases 1–7 (worker execution, validation, review, correction, budget, publication, observability) | Not started |

## Repository Layout

```text
docs\       architecture and governance documents
config\     project configuration and state
policies\   governance policies, including BUDGET_POLICY.json
schemas\    JSON Schema contracts for inter-agent artifacts
scripts\    deterministic Supervisor scripts (PowerShell)
src\        implementation source
tests\      tests for deterministic contracts
```

Runtime data lives **outside** this repository, under `C:\tmp\ai-orchestra-worktrees\` and
`C:\tmp\ai-orchestra-runs\`. Disposable worktrees and transient logs must never be committed here.

## Source of Truth

Architecture and governance are defined by
[`docs\AI_ORCHESTRA_GUIDELINES.md`](docs/AI_ORCHESTRA_GUIDELINES.md).

That document takes precedence over this README. Any AI agent assigned work on this repository must
read it before implementation, must not redesign the architecture, and must report assumptions
rather than silently inventing requirements.

## Environment

Windows-first: PowerShell, Git, GitHub CLI. No external frameworks or services are used in the MVP.

Credentials are managed by the host environment (Git Credential Manager / authenticated GitHub CLI)
and must never appear in tasks, reports, prompts, logs or repository files.
