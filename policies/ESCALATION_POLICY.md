# ESCALATION_POLICY

**Version:** 0.1
**Status:** Initial deterministic rules
**Authority:** Subordinate to `docs\AI_ORCHESTRA_GUIDELINES.md`. Companion to
`ORCHESTRATOR_POLICY.md`, which owns the state machine.

This document defines when a run halts at `HUMAN_REQUIRED` and what the human may then do.

---

## 1. Principles

1. `HUMAN_REQUIRED` is a halt, not a failure. Work performed so far is preserved.
2. No agent may bypass, clear or override `HUMAN_REQUIRED`.
3. Escalation is the default when a rule is ambiguous, evidence is missing, or a limit is reached.
   Escalating unnecessarily is cheap; proceeding wrongly is not.
4. A trigger is evaluated deterministically by the Supervisor wherever possible. Agent-reported
   triggers are accepted as *requests to escalate*, never as authority to continue.
5. Every escalation records: `task_id`, the state it halted in, the trigger, the evidence, and the
   timestamp.
6. Execution resumes only through an explicit, recorded human action from Section 3.

`HUMAN_REQUIRED` is reachable from every non-terminal state
(`ORCHESTRATOR_POLICY.md` Section 2.1).

---

## 2. HUMAN_REQUIRED Triggers

Each trigger has a stable identifier for use in the `reason` field of `STATUS.json` and in the audit
trail.

### 2.1 Budget and iteration

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Budget exhausted | `budget_exhausted` | Any hard limit in `policies\BUDGET_POLICY.json` is reached: `max_total_tokens`, `max_worker_calls`, `max_reviewer_calls`, `max_runtime_seconds`. | Supervisor |
| Correction limit reached | `correction_limit_reached` | A correction is requested while `correction_rounds >= max_correction_rounds`. | Supervisor |

Crossing `warning_tokens` is recorded only and does not escalate.

### 2.2 Architecture and requirements

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Architecture change | `architecture_change` | Completing the task would materially change the architecture, introduce a framework, service or dependency, or alter a defined contract or schema. | Agent report / reviewer |
| Conflicting requirements | `conflicting_requirements` | The objective, acceptance criteria, policies or repository state cannot all be satisfied simultaneously. | Agent report / reviewer / Supervisor |

An agent must report these rather than resolve them. Guidelines section 22 rule 9: report
assumptions instead of silently inventing requirements.

### 2.3 Security and credentials

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Security-sensitive change | `security_sensitive_change` | A change touches authentication, authorization, credential handling, CI/CD or deployment configuration, or the security validator flags the diff. | Security validator |
| Secrets required | `secrets_required` | Completing the task would require a credential, token, key or `.env` value that is not already available to the host environment. | Agent report / Supervisor |
| Destructive migration | `destructive_migration` | A change would drop, rewrite or irreversibly transform persistent data or schema. | Agent report / reviewer |

Raw credentials must never appear in a task, report, prompt, log or repository file. An escalation
records that a secret is needed — never the secret itself.

### 2.4 Git and publication

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Force push required | `force_push_required` | Publication cannot proceed without `git push --force`. | Supervisor |
| Protected branch modification | `protected_branch_modification` | The task or publication targets a protected branch, or a merge into one is required. | Supervisor |

These are refusals, not warnings. The Supervisor does not perform the operation and does not ask an
agent whether it should.

### 2.5 Verification and disagreement

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Unverifiable output | `unverifiable_output` | A required artifact is missing, unparseable or schema-invalid; a `decision`/`next_action` pair is invalid after the retry allowed by `ORCHESTRATOR_POLICY.md` Section 3.4; a worker claim cannot be checked against Git or test evidence; or a validator cannot run. | Supervisor |
| Unresolved critical disagreement | `critical_disagreement` | The reviewer reports a `critical` finding the worker contests, or worker and reviewer give irreconcilable accounts of the same verifiable fact. | Supervisor / reviewer |

A worker claim contradicted by `git diff --name-only`, an exit code or a validator result is treated
as unverifiable output, not as a difference of opinion.

### 2.6 Privilege

| Trigger | Identifier | Condition | Detected by |
| --- | --- | --- | --- |
| Privilege escalation request | `privilege_escalation_request` | An agent requests capability beyond its current level: publication rights for a worker, additional budget or iterations, wider `allowed_paths`, access to `forbidden_paths`, a forbidden Git operation, or relaxation of any invariant. | Supervisor |

The request is recorded and refused. An agent never receives privilege because a task appears to
require it.

### 2.7 Catch-all

| Trigger | Identifier | Condition |
| --- | --- | --- |
| Undefined situation | `undefined_situation` | The Supervisor encounters a condition no rule covers, including a rejected state transition. |

Default behaviour in the absence of a rule is to halt, not to improvise.

---

## 3. Human Actions

Exactly six actions are defined. Each is recorded with an actor and a timestamp, and each maps to
one transition (`ORCHESTRATOR_POLICY.md` Section 6).

| Action | Meaning | Transition | Preconditions |
| --- | --- | --- | --- |
| `APPROVE` | The human accepts the work as it stands and authorizes publication. | `HUMAN_REQUIRED -> APPROVED` | The escalation occurred at or after `REVIEWING`, and the change is implemented and validated. Publication still executes under Git policy — `APPROVE` does not authorize a force push, a merge, or a protected-branch write. |
| `REJECT` | The work is not acceptable and the run ends. | `HUMAN_REQUIRED -> FAILED` | None. Terminal. |
| `MODIFY_SCOPE` | The task definition changes and the run restarts from planning. | `HUMAN_REQUIRED -> PLANNING` | An updated `TASK.json` valid against `schemas\TASK.schema.json`. |
| `INCREASE_BUDGET` | New limits are granted for this run. | `HUMAN_REQUIRED -> PLANNING` | Explicit new values. Consumed counters are not reset. |
| `RETRY` | Re-attempt from the current repository state without changing scope or budget. | `HUMAN_REQUIRED -> PLANNING` | Remaining budget must be sufficient, otherwise `INCREASE_BUDGET` is required first. |
| `CANCEL` | The run is abandoned. | `HUMAN_REQUIRED -> CANCELLED` | None. Terminal. |

Rules:

1. Counters (`worker_calls`, `reviewer_calls`, `correction_rounds`) are never reset by a human action.
   `INCREASE_BUDGET` raises limits; it does not erase consumption.
2. `INCREASE_BUDGET` does not amend `policies\BUDGET_POLICY.json`. Changing the default policy is a
   separate, deliberate act.
3. `APPROVE` cannot authorize an operation the Git policy forbids. A forbidden operation stays
   forbidden.
4. A human action may not be inferred from silence, from an agent's assertion, or from a timeout.
   Absent an action, the run stays halted.
5. An action that raises a limit or widens scope is itself an auditable event.
6. A human decision may optionally specify a `resume_state`. The Supervisor must validate it. Safe
   MVP resume destinations from `HUMAN_REQUIRED` are limited to `PLANNING`, `WORKER_RUNNING`,
   `VALIDATING`, `REVIEWING`, and `APPROVED`. Direct resume to `PUBLISHING`, `PUBLISHED`, or any
   other terminal state is forbidden and will be rejected.

---

## 4. Escalation Record

Every escalation records at least:

```text
task_id
state at halt
trigger identifier
evidence (validator output, exit code, changed-file list, artifact reference)
timestamp
```

And on resumption, a human decision is recorded as `HUMAN_DECISION.json` at:
`C:\tmp\ai-orchestra-runs\<run-id>\HUMAN_DECISION.json`

This file conforms to `schemas\HUMAN_DECISION.schema.json` and forms an immutable part of the run's audit trail, documenting:

```text
human action
actor
reason
timestamp
resume_state (optional)
budget_override (optional)
```

Evidence and decision files must never contain credentials, tokens or secret values.

---

## ARCHITECTURAL NOTES

Open items recorded rather than silently decided:

1. Detection of `architecture_change`, `conflicting_requirements`, `secrets_required` and
   `destructive_migration` is not fully deterministic today; it currently depends on an agent
   reporting honestly. Deterministic detectors (dependency-manifest diffs, migration-file patterns)
   would strengthen these and belong in `SECURITY_POLICY.md` and the validator design.
2. The protected-branch list is undefined for this repository. `force_push_required` and
   `protected_branch_modification` cannot be enforced deterministically until `GIT_POLICY.md` names
   it.
3. The human action is codified in `HUMAN_DECISION.json` conforming to `schemas\HUMAN_DECISION.schema.json`.
4. No identity or authentication model exists for "the human". The `actor` field is descriptive
   only.
