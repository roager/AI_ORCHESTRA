# AI_ORCHESTRA
## Architecture, Governance & Implementation Guidelines

**Version:** 0.1  
**Status:** Initial Architecture  
**Primary Environment:** Windows / PowerShell / Git / GitHub  
**Project Root:** `C:\Users\roage\OneDrive\Documents\CODE\AI_ORCHESTRA`  
**Runtime Workspace Root:** `C:\tmp\ai-orchestra-worktrees`

---

# 1. Purpose

AI_ORCHESTRA is a lightweight local orchestration system for coordinating AI software-development agents.

The initial agents are:

- Codex CLI
- Claude Code CLI

The architecture must allow additional agents to be introduced later without redesigning the orchestration model.

AI_ORCHESTRA is not intended to become a general-purpose agent framework during its MVP phase.

Its purpose is to provide a controlled, auditable and cost-bounded mechanism to:

1. Define development tasks.
2. Delegate implementation or analysis to an appropriate agent.
3. Isolate each task in its own Git worktree.
4. Validate agent output deterministically whenever possible.
5. Allow an independent agent to review work.
6. Limit autonomous correction loops.
7. Enforce token, runtime and invocation budgets.
8. Publish approved changes through Git/GitHub.
9. Escalate uncertain, sensitive or high-impact decisions to a human.
10. Preserve an audit trail of every automated run.

PODIUMHUB will initially be used as a real-world integration and validation project, but AI_ORCHESTRA must not contain PODIUMHUB-specific assumptions in its core architecture.

---

# 2. Core Roles

The initial architecture separates four responsibilities.

## 2.1 Human

The human remains the ultimate authority.

Responsibilities include:

- defining strategic intent;
- approving sensitive decisions;
- resolving escalations;
- changing policies;
- authorizing expansion of autonomous capabilities;
- terminating runs when necessary.

No agent may bypass a `HUMAN_REQUIRED` state.

## 2.2 Codex

Codex initially acts as:

- planner;
- orchestrator-level reasoning agent;
- independent reviewer;
- publication authority.

Codex may determine whether completed work satisfies the task and whether it is safe to publish.

Codex is not the operating-system security boundary. Deterministic policies must still constrain privileged actions.

## 2.3 Worker Agent

Claude Code is the initial primary worker agent.

Other agents, such as Gemini or future coding agents, may later perform this role.

A worker agent may:

- inspect an assigned repository;
- implement a bounded task;
- modify authorized files;
- execute authorized development commands;
- execute tests;
- analyze failures;
- return structured results.

Worker agents must not automatically inherit publication privileges.

## 2.4 Supervisor

The Supervisor is deterministic code, initially implemented primarily in PowerShell.

It does not make architectural or product decisions.

It:

- creates workspaces;
- invokes agents;
- validates state transitions;
- validates structured output;
- checks Git state;
- enforces scope;
- enforces budgets;
- enforces iteration limits;
- manages timeouts;
- records logs;
- invokes approved publication operations;
- stops execution when policy requires escalation.

Whenever a decision can be made reliably by deterministic code instead of an LLM, the Supervisor should make it.

---

# 3. High-Level Architecture

```text
                     HUMAN
                       │
                       ▼
                     CODEX
              Planner / Reviewer
                       │
                    TASK
                       │
                       ▼
                  WORKER AGENT
                 Claude / Other
                       │
                    RESULT
                       │
                       ▼
                  VALIDATORS
             schema / scope / tests
                git / security
                       │
                       ▼
                     CODEX
                      Review
                       │
             ┌─────────┼─────────┐
             ▼         ▼         ▼
          CORRECT    ACCEPT     HUMAN
             │         │       REQUIRED
             │         ▼
             │      PUBLISH
             │         │
             └────► Worker       ▼
                                GitHub
```

The architecture deliberately separates:

**reasoning → execution → validation → authorization → publication**

These responsibilities must not collapse into unrestricted agent autonomy.

---

# 4. Design Principles

## 4.1 Deterministic Before Agentic

AI reasoning consumes resources and introduces uncertainty.

Anything that can reliably be determined through code should be handled deterministically.

Examples:

- current Git branch;
- changed files;
- path authorization;
- JSON validity;
- test exit codes;
- iteration count;
- runtime;
- budget thresholds;
- presence of forbidden files;
- repository cleanliness.

Do not invoke an AI agent merely to discover information already available to the operating system or Git.

## 4.2 One Task, One Worktree

Every implementation task must execute inside an isolated Git worktree.

Runtime worktrees must not live inside the AI_ORCHESTRA source repository.

Default runtime location:

```text
C:\tmp\ai-orchestra-worktrees\
```

Example:

```text
C:\tmp\ai-orchestra-worktrees\
└── podiumhub-epic26-d4-003\
```

Agents must not modify the developer's primary working copy unless explicitly authorized by policy.

## 4.3 Source Code and Runtime Data Are Separate

AI_ORCHESTRA source code lives at:

```text
C:\Users\roage\OneDrive\Documents\CODE\AI_ORCHESTRA
```

Temporary execution data, worktrees and disposable artifacts should live outside the source repository.

Recommended separation:

```text
C:\Users\roage\OneDrive\Documents\CODE\
└── AI_ORCHESTRA\
    ├── docs\
    ├── policies\
    ├── schemas\
    ├── scripts\
    ├── config\
    ├── tests\
    └── src\

C:\tmp\
├── ai-orchestra-worktrees\
└── ai-orchestra-runs\
```

OneDrive should contain source-controlled project artifacts, not large transient agent logs or disposable worktrees.

---

# 5. Filesystem as Shared Memory

Agents should not communicate through unrestricted conversational transcripts.

AI_ORCHESTRA uses small structured artifacts as its primary inter-agent protocol.

Examples:

```text
TASK.json
STATUS.json
WORKER_REPORT.json
REVIEW.json
RESULT.json
USAGE.json
HUMAN_DECISION.json
```

Large repository contents should not be copied into these objects.

Agents should inspect the actual repository when they require source context.

Git is the authoritative source for code changes.

---

# 6. Bounded Agent Interaction

Unrestricted autonomous conversation between agents is prohibited.

Normal lifecycle:

```text
Planner
   ↓
Worker
   ↓
Reviewer
```

One correction cycle may initially be permitted:

```text
Planner
   ↓
Worker
   ↓
Reviewer
   ↓
Worker Correction
   ↓
Reviewer Final
```

The MVP default is:

```text
MAX_CORRECTION_ROUNDS = 1
```

If additional correction would be required:

```text
HUMAN_REQUIRED
```

An agent cannot grant itself additional iterations.

---

# 7. State Machine

Initial states:

```text
CREATED
PLANNING
WORKER_RUNNING
WORKER_DONE
VALIDATING
REVIEWING
CORRECTION_REQUIRED
APPROVED
PUBLISHING
PUBLISHED
HUMAN_REQUIRED
FAILED
CANCELLED
```

Normal successful lifecycle:

```text
CREATED
   ↓
PLANNING
   ↓
WORKER_RUNNING
   ↓
WORKER_DONE
   ↓
VALIDATING
   ↓
REVIEWING
   ↓
APPROVED
   ↓
PUBLISHING
   ↓
PUBLISHED
```

Correction lifecycle:

```text
REVIEWING
    ↓
CORRECTION_REQUIRED
    ↓
WORKER_RUNNING
    ↓
WORKER_DONE
    ↓
VALIDATING
    ↓
REVIEWING
```

If another correction exceeds policy:

```text
HUMAN_REQUIRED
```

Every state transition must be recorded.

---

# 8. Mandatory MVP Invariants

The following rules are mandatory:

```text
ONE_TASK_ONE_WORKTREE

NO_DIRECT_PUSH_TO_PROTECTED_BRANCH

NO_FORCE_PUSH

NO_AUTOMATIC_MERGE

NO_SECRETS_IN_AGENT_ARTIFACTS

NO_UNBOUNDED_AGENT_LOOPS

MAX_CORRECTION_ROUNDS = 1

BUDGET_ENFORCED_OUTSIDE_THE_AGENT

AGENTS_CANNOT_SELF_ELEVATE_PRIVILEGES

OUT_OF_SCOPE_CHANGES_CANNOT_BE_SILENTLY_PUBLISHED

EVERY_RUN_HAS_AN_AUDIT_TRAIL
```

Agents may not silently relax these constraints.

---

# 9. Task Contract

Each task must have a machine-readable definition.

Illustrative example:

```json
{
  "task_id": "podiumhub-epic26-d4-003",
  "project": "PODIUMHUB",
  "repository": "owner/PODIUMHUB",
  "branch": "agent/epic26-d4-003",
  "workspace": "C:\\tmp\\ai-orchestra-worktrees\\podiumhub-epic26-d4-003",
  "objective": "Implement D4",
  "allowed_paths": [
    "src/api",
    "tests/api"
  ],
  "forbidden_paths": [
    ".github",
    "infra"
  ],
  "acceptance_criteria": [
    "Required behavior is implemented",
    "Relevant tests pass",
    "No unauthorized files are modified"
  ]
}
```

The formal contract will be defined through JSON Schema.

---

# 10. Worker Result Contract

Worker agents must produce concise structured reports.

Illustrative example:

```json
{
  "status": "completed",
  "files_changed": [
    "src/api/foo.py",
    "tests/api/test_foo.py"
  ],
  "tests": {
    "command": "pytest tests/api",
    "passed": 34,
    "failed": 0
  },
  "summary": "Implemented requested endpoint.",
  "risks": [],
  "questions": []
}
```

The report must not contain unnecessary source-code dumps.

Claims made by the worker must be independently verifiable whenever practical.

---

# 11. Review Contract

The reviewer must inspect actual repository state and not rely exclusively on the worker's report.

Illustrative acceptance:

```json
{
  "decision": "ACCEPT",
  "scope_valid": true,
  "tests_valid": true,
  "findings": [],
  "next_action": "PUBLISH"
}
```

Illustrative correction:

```json
{
  "decision": "CORRECT",
  "findings": [
    {
      "severity": "major",
      "file": "src/api/foo.py",
      "issue": "Incorrect error handling"
    }
  ]
}
```

Initial review decisions:

```text
ACCEPT
CORRECT
HUMAN_REQUIRED
```

---

# 12. Budget Governance

AI_ORCHESTRA must prevent uncontrolled model consumption.

Initial provisional limits:

```json
{
  "max_total_tokens": 40000,
  "warning_tokens": 30000,
  "max_worker_calls": 2,
  "max_reviewer_calls": 3,
  "max_correction_rounds": 1,
  "max_runtime_seconds": 2700
}
```

These values are starting assumptions, not permanent architecture.

Real usage must be measured.

Future budgets should be based on observed task classes and historical consumption.

The Supervisor owns enforcement.

Agents may report consumption but cannot authorize additional budget.

When a hard limit is reached:

```text
HUMAN_REQUIRED
```

---

# 13. Context Efficiency

Agent invocations should receive the smallest useful context.

Typical context:

```text
task
relevant policy
current state
short prior-agent result
workspace location
```

Agents should inspect source files directly when required.

Avoid repeatedly sending:

- entire conversation histories;
- entire repositories;
- large previous model outputs;
- source files already available locally;
- large diffs available through Git.

Filesystem and Git state are cheaper and more reliable persistent memory than repeated prompt context.

---

# 14. Deterministic Validation

Before AI review, the Supervisor should execute applicable validators.

Initial validators:

## Schema Validator

Validates structured artifacts against their JSON Schemas.

## Scope Validator

Compares actual changed files with task authorization.

Typical source:

```text
git diff --name-only
```

## Test Validator

Executes configured test commands and records:

- command;
- exit code;
- pass/fail;
- relevant output.

## Git Validator

Checks:

- repository identity;
- worktree;
- branch;
- clean baseline;
- unexpected Git state;
- forbidden publication targets.

## Security Validator

Checks for obvious unauthorized changes involving:

- `.env`;
- credentials;
- tokens;
- secrets;
- authentication configuration;
- GitHub configuration;
- deployment configuration.

A failed validator cannot be silently ignored.

---

# 15. Git and GitHub Governance

The publication layer may eventually support:

```text
git status
git diff
git add
git commit
git push <authorized-task-branch>

gh pr create
gh pr edit
```

Initially forbidden:

```text
git push --force

direct push to main

direct push to master

automatic merge

remote protected-branch deletion

GitHub secret modification

repository permission modification
```

Credentials should remain managed by the host environment through mechanisms such as Git Credential Manager or authenticated GitHub CLI.

Raw credentials must not be stored in:

```text
TASK.json
STATUS.json
agent prompts
reports
logs
repository files
```

---

# 16. Publication Authority

The reasoning authority and execution mechanism should remain distinct.

A reviewer may return:

```json
{
  "decision": "ACCEPT",
  "next_action": "PUBLISH"
}
```

The deterministic publication component then performs only operations permitted by Git policy.

This allows AI_ORCHESTRA to prevent operations such as:

```text
push main
force push
merge
```

even if an agent mistakenly requests them.

---

# 17. Human Escalation & Resumption

At minimum, execution becomes `HUMAN_REQUIRED` when:

- correction limit is reached;
- budget is exhausted;
- architecture must materially change;
- requirements conflict;
- security behavior must change;
- credentials or secrets are required;
- destructive migration is proposed;
- protected CI/CD configuration must change outside task scope;
- force push appears necessary;
- merge requires human authorization;
- agent output cannot be validated;
- critical disagreement between agents remains unresolved;
- requested action exceeds current privilege level.

On resumption, the human action is recorded in `HUMAN_DECISION.json` under:
`C:\tmp\ai-orchestra-runs\<run-id>\HUMAN_DECISION.json`

This file conforms to the `HUMAN_DECISION.schema.json` schema and constitutes part of the run's audit trail.

The human actions are:
- `APPROVE` (resumes at `APPROVED`)
- `REJECT` (ends run as `FAILED`)
- `MODIFY_SCOPE` (resumes at `PLANNING` or specified state)
- `INCREASE_BUDGET` (resumes at `PLANNING` or specified state)
- `RETRY` (resumes at `PLANNING` or specified state)
- `CANCEL` (ends run as `CANCELLED`)

### Resumption Validation Semantics
If the human decision specifies an explicit destination using `resume_state`, the Supervisor must validate it. Safe MVP resume destinations are limited to:
- `PLANNING`
- `WORKER_RUNNING`
- `VALIDATING`
- `REVIEWING`
- `APPROVED`

Direct resumption to `PUBLISHING`, `PUBLISHED`, or any other terminal/forbidden state is strictly prohibited.

All such interventions should eventually be auditable.

---

# 18. Initial Repository Structure

The source repository should initially use:

```text
AI_ORCHESTRA\
│
├── README.md
├── .gitignore
│
├── docs\
│   └── AI_ORCHESTRA_GUIDELINES.md
│
├── config\
│   └── PROJECT_STATE.json
│
├── policies\
│   ├── ORCHESTRATOR_POLICY.md
│   ├── WORKER_POLICY.md
│   ├── CODEX_POLICY.md
│   ├── GIT_POLICY.md
│   ├── SECURITY_POLICY.md
│   ├── ESCALATION_POLICY.md
│   └── BUDGET_POLICY.json
│
├── schemas\
│   ├── TASK.schema.json
│   ├── WORKER_REPORT.schema.json
│   ├── REVIEW.schema.json
│   ├── STATUS.schema.json
│   └── RESULT.schema.json
│
├── scripts\
│   ├── New-AgentWorktree.ps1
│   ├── Invoke-Worker.ps1
│   ├── Invoke-Codex.ps1
│   ├── Test-AgentScope.ps1
│   ├── Test-AgentBudget.ps1
│   ├── Test-AgentState.ps1
│   ├── Publish-AgentChanges.ps1
│   └── Remove-AgentWorktree.ps1
│
├── src\
│
└── tests\
```

Runtime data remains outside the repository:

```text
C:\tmp\
├── ai-orchestra-worktrees\
└── ai-orchestra-runs\
```

---

# 19. MVP Scope

The MVP must demonstrate:

> A real development task can be planned, delegated to a worker agent, executed inside an isolated Git worktree, validated deterministically, independently reviewed, corrected at most once, and published as a GitHub branch/PR without exceeding defined security, autonomy or budget boundaries.

PODIUMHUB will initially serve as the real-world validation repository.

---

# 20. Explicit MVP Non-Goals

The MVP does not require:

- graphical user interface;
- database;
- cloud orchestration service;
- autonomous agent-to-agent chat;
- multiple concurrent task queues;
- distributed execution;
- automatic merge;
- automatic production deployment;
- generalized enterprise workflow engine;
- persistent autonomous agents.

These capabilities require demonstrated need before introduction.

---

# 21. Implementation Phases

## Phase 0 — Foundation

Create:

- repository;
- guidelines;
- policies;
- schemas;
- basic configuration;
- tests for deterministic contracts.

## Phase 1 — Worker Execution

Create an isolated worktree and reliably invoke a worker agent.

## Phase 2 — Validation

Implement:

- schema validation;
- scope validation;
- Git validation;
- test execution;
- basic security validation.

## Phase 3 — Independent Review

Allow Codex to review:

- task;
- worker report;
- actual diff;
- validator results.

## Phase 4 — Controlled Correction

Permit one bounded correction cycle.

## Phase 5 — Budget Enforcement

Track and enforce:

- agent calls;
- correction rounds;
- runtime;
- available token usage.

## Phase 6 — Publication

Permit approved work to:

- commit;
- push task branch;
- create/update pull request.

## Phase 7 — Observability

Record:

- duration;
- agent calls;
- iterations;
- validation failures;
- escalation reasons;
- token consumption when available;
- publication result.

---

# 22. Rules for AI Agents Developing AI_ORCHESTRA

Any AI agent assigned implementation work on this repository must follow these rules:

1. Read this document before implementation.
2. Read the specific policies and schemas relevant to the assigned task.
3. Do not redesign the overall architecture unless explicitly assigned to do so.
4. Do not implement unrelated components.
5. Do not introduce frameworks, services or infrastructure without explicit justification and approval.
6. Prefer PowerShell, Git and structured files for the MVP.
7. Keep the implementation Windows-first.
8. Keep components independently testable.
9. Report assumptions instead of silently inventing requirements.
10. Do not weaken security, budget or escalation rules to simplify implementation.
11. Do not grant an agent additional privileges merely because a task requires them.
12. Preserve compatibility with future worker agents where practical.
13. Keep prompts and inter-agent artifacts concise.
14. Prefer observable and auditable behavior over hidden automation.
15. Complexity must be justified by demonstrated need.

---

# 23. Architectural Principle

AI_ORCHESTRA should remain deliberately understandable.

The objective is not maximum autonomy.

The objective is:

> **Useful autonomy inside explicit boundaries, with deterministic enforcement and human authority.**

If a feature makes the system substantially harder to understand, audit, stop or recover, it requires strong justification before inclusion.
