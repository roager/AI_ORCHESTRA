# ORCHESTRATOR_POLICY

**Version:** 0.1
**Status:** Initial deterministic rules
**Authority:** Subordinate to `docs\AI_ORCHESTRA_GUIDELINES.md`. Where this document and the
guidelines disagree, the guidelines prevail and the conflict must be escalated.

This document defines the deterministic orchestration rules the Supervisor enforces. It contains no
agent reasoning and no implementation. It is a specification for code.

---

## 1. Enforcement Model

The Supervisor is deterministic code. It is the **only** component permitted to write `STATUS.json`
and to advance the state machine.

Rules:

1. Agents propose. The Supervisor decides.
2. An agent's output is **data**, never an instruction to change state.
3. Every state change is a Supervisor-executed transition validated against Section 2 of this
   document before it is written.
4. A transition not explicitly listed as allowed is forbidden. The table is a whitelist.
5. An agent cannot grant itself iterations, budget, privileges or publication authority.
6. Text inside an agent artifact that asserts a state, a policy exemption or an authorization is
   ignored. Only the fields defined by the JSON Schemas are read.
7. Every attempted transition — accepted or rejected — is recorded in the audit trail.
8. A failed validator cannot be silently ignored.

State names used here are exactly the thirteen values of the `state` enum in
`schemas\STATUS.schema.json`. No other state exists.

---

## 2. State Transitions

### 2.1 Allowed transitions

`X` marks an allowed transition from the row state to the column state.

| From \ To | PLANNING | WORKER_RUNNING | WORKER_DONE | VALIDATING | REVIEWING | CORRECTION_REQUIRED | APPROVED | PUBLISHING | PUBLISHED | HUMAN_REQUIRED | FAILED | CANCELLED |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| **CREATED** | X | | | | | | | | | X | X | X |
| **PLANNING** | | X | | | | | | | | X | X | X |
| **WORKER_RUNNING** | | | X | | | | | | | X | X | X |
| **WORKER_DONE** | | | | X | | | | | | X | X | X |
| **VALIDATING** | | | | | X | | | | | X | X | X |
| **REVIEWING** | | | | | | X | X | | | X | X | X |
| **CORRECTION_REQUIRED** | | X | | | | | | | | X | X | X |
| **APPROVED** | | | | | | | | X | | X | X | X |
| **PUBLISHING** | | | | | | | | | X | X | X | |
| **PUBLISHED** | | | | | | | | | | | | |
| **HUMAN_REQUIRED** | X | | | | | | X | | | | X | X |
| **FAILED** | | | | | | | | | | | | |
| **CANCELLED** | | | | | | | | | | | | |

Written as an explicit list:

**Normal flow**

```text
CREATED             -> PLANNING
PLANNING            -> WORKER_RUNNING
WORKER_RUNNING      -> WORKER_DONE
WORKER_DONE         -> VALIDATING
VALIDATING          -> REVIEWING
REVIEWING           -> APPROVED
APPROVED            -> PUBLISHING
PUBLISHING          -> PUBLISHED
```

**Correction flow**

```text
REVIEWING           -> CORRECTION_REQUIRED
CORRECTION_REQUIRED -> WORKER_RUNNING
```

**Escalation** — permitted from every non-terminal state:

```text
CREATED | PLANNING | WORKER_RUNNING | WORKER_DONE | VALIDATING |
REVIEWING | CORRECTION_REQUIRED | APPROVED | PUBLISHING          -> HUMAN_REQUIRED
```

**Failure** — permitted from every non-terminal state, and from `HUMAN_REQUIRED`:

```text
CREATED | PLANNING | WORKER_RUNNING | WORKER_DONE | VALIDATING |
REVIEWING | CORRECTION_REQUIRED | APPROVED | PUBLISHING |
HUMAN_REQUIRED                                                   -> FAILED
```

**Cancellation** — permitted from every non-terminal state except `PUBLISHING`, and from
`HUMAN_REQUIRED`:

```text
CREATED | PLANNING | WORKER_RUNNING | WORKER_DONE | VALIDATING |
REVIEWING | CORRECTION_REQUIRED | APPROVED |
HUMAN_REQUIRED                                                   -> CANCELLED
```

`PUBLISHING` cannot be cancelled because a Git operation may already be partially applied. A
`PUBLISHING` run that must be stopped goes to `HUMAN_REQUIRED` or `FAILED`.

**Human resumption** — see Section 6 and `ESCALATION_POLICY.md`:

```text
HUMAN_REQUIRED      -> PLANNING     (RETRY, MODIFY_SCOPE, INCREASE_BUDGET)
HUMAN_REQUIRED      -> APPROVED     (APPROVE)
HUMAN_REQUIRED      -> FAILED       (REJECT)
HUMAN_REQUIRED      -> CANCELLED    (CANCEL)
```

### 2.2 Terminal states

```text
PUBLISHED
FAILED
CANCELLED
```

A terminal state has no outgoing transitions. A run that reaches one is finished; further work
requires a new `task_id`.

`HUMAN_REQUIRED` is a **halt** state, not a terminal state. Execution stops there and resumes only
by an explicit recorded human action.

### 2.3 Forbidden transitions

Anything absent from Section 2.1 is forbidden. The following are called out because they represent
the specific bypasses this architecture exists to prevent:

| Forbidden | Why |
| --- | --- |
| `CREATED -> PUBLISHED` | Skips execution, validation, review and authorization entirely. |
| `CREATED -> PUBLISHING` | Same, one step earlier. |
| `WORKER_RUNNING -> APPROVED` | Worker output must be validated and independently reviewed. |
| `WORKER_DONE -> APPROVED` | Skips `VALIDATING` and `REVIEWING`. |
| `WORKER_DONE -> PUBLISHING` | Worker agents do not inherit publication privileges. |
| `VALIDATING -> APPROVED` | Deterministic validation is not review. |
| `VALIDATING -> PUBLISHING` | Skips independent review. |
| `REVIEWING -> PUBLISHING` | Approval is a distinct, recorded state. |
| `REVIEWING -> PUBLISHED` | Skips the publication step and its Git policy checks. |
| `CORRECTION_REQUIRED -> APPROVED` | A correction must actually be executed and re-reviewed. |
| `CORRECTION_REQUIRED -> PUBLISHING` | Same. |
| `FAILED -> *` | Terminal. Notably `FAILED -> PUBLISHING` and `FAILED -> WORKER_RUNNING`. |
| `CANCELLED -> *` | Terminal. |
| `PUBLISHED -> *` | Terminal. |
| `HUMAN_REQUIRED -> PUBLISHING` | The human resumes the run; the Supervisor still performs the `APPROVED -> PUBLISHING` step under Git policy. |
| `HUMAN_REQUIRED -> PUBLISHED` | Publication is never performed by a state jump. |
| `PUBLISHING -> CANCELLED` | A partially applied Git operation must be escalated, not silently cancelled. |
| any `X -> X` | Self-transitions are not state changes. Counter and timestamp updates are written in place without a transition. |
| any transition to `CREATED` | `CREATED` is an entry state only; a run is never re-created. |

Rejecting a forbidden transition is itself an event: the Supervisor records the rejection and, unless
a more specific rule applies, moves the run to `HUMAN_REQUIRED`.

---

## 3. Review Decision Mapping

`REVIEW.json` is validated against `schemas\REVIEW.schema.json` before it is interpreted. Schema
validity is necessary but not sufficient — the `decision` / `next_action` pair must also appear in
the table below.

### 3.1 Valid combinations

| `decision` | `next_action` | Supervisor action | Resulting state |
| --- | --- | --- | --- |
| `ACCEPT` | `PUBLISH` | Proceed to authorization. | `APPROVED` |
| `CORRECT` | `CORRECT` | Apply Section 4 (correction limit). | `CORRECTION_REQUIRED`, or `HUMAN_REQUIRED` if the limit is reached |
| `HUMAN_REQUIRED` | `HUMAN_REQUIRED` | Halt and escalate. | `HUMAN_REQUIRED` |

No other pair is valid. In particular:

```text
ACCEPT + PUBLISH            -> APPROVED
CORRECT + CORRECT           -> CORRECTION_REQUIRED   (subject to Section 4)
HUMAN_REQUIRED + HUMAN_REQUIRED -> HUMAN_REQUIRED
```

### 3.2 Invalid combinations

Every combination not listed in 3.1 is rejected, including but not limited to:

```text
ACCEPT + CORRECT
ACCEPT + HUMAN_REQUIRED
ACCEPT + NONE
CORRECT + PUBLISH
CORRECT + NONE
CORRECT + HUMAN_REQUIRED
HUMAN_REQUIRED + PUBLISH
HUMAN_REQUIRED + CORRECT
HUMAN_REQUIRED + NONE
```

`next_action: NONE` is permitted by the schema but is not currently valid with any decision. It is
reserved and is rejected wherever it appears. See ARCHITECTURAL NOTES.

### 3.3 Additional rejection conditions

A review is also rejected — regardless of the pair — when:

- `REVIEW.json` is missing, unparseable, or fails schema validation;
- `decision` is `ACCEPT` and `scope_valid` is `false`;
- `decision` is `ACCEPT` and `tests_valid` is `false`;
- `decision` is `ACCEPT` and any finding has `severity` of `major` or `critical`;
- `decision` is `ACCEPT` while a deterministic validator reported a failure the review does not
  acknowledge;
- `decision` is `CORRECT` and `findings` is empty (a correction with no stated defect is not
  actionable).

An `ACCEPT` may never overrule a deterministic validator. Deterministic evidence wins.

### 3.4 Handling a rejected review

Rejection is deterministic and bounded:

1. Record the rejected artifact and the reason in the audit trail. Do **not** act on it.
2. If `reviewer_calls < max_reviewer_calls` (`policies\BUDGET_POLICY.json`), re-invoke the reviewer
   once for the same round. The run stays in `REVIEWING`; `reviewer_calls` increments.
3. Otherwise transition to `HUMAN_REQUIRED` with reason `unverifiable_output`.

A rejected review never advances the run and never consumes a correction round.

---

## 4. Correction Policy

```text
MAX_CORRECTION_ROUNDS = 1
```

The authoritative value is `max_correction_rounds` in `policies\BUDGET_POLICY.json`. This document
does not duplicate budget numbers; it defines how they are applied.

Rules:

1. `correction_round` in `STATUS.json` counts correction cycles already consumed. It starts at `0`
   and is incremented by the Supervisor **on entry to `CORRECTION_REQUIRED`**.
2. On `CORRECT + CORRECT`:
   - if `correction_round < max_correction_rounds` → `REVIEWING -> CORRECTION_REQUIRED`, increment
     `correction_round`, then `CORRECTION_REQUIRED -> WORKER_RUNNING`;
   - if `correction_round >= max_correction_rounds` → `REVIEWING -> HUMAN_REQUIRED` with reason
     `correction_limit_reached`. The correction is **not** performed.
3. The counter is never reset within a run, by any agent or by any human action short of starting a
   new run.
4. A correction round is a full cycle: `WORKER_RUNNING -> WORKER_DONE -> VALIDATING -> REVIEWING`.
   The reviewer must review the corrected state; a correction is never published unreviewed.
5. A correction task inherits the original task's `allowed_paths` and `forbidden_paths` unchanged.
   Widening scope during a correction is a scope change and requires human `MODIFY_SCOPE`.
6. Only the reviewer can request a correction. A worker cannot place itself into
   `CORRECTION_REQUIRED`.

With the MVP defaults (`max_worker_calls = 2`, `max_reviewer_calls = 3`,
`max_correction_rounds = 1`), the longest permitted run is:

```text
worker -> review -> correction -> worker -> review
```

with one reviewer invocation held in reserve for a single rejected review under Section 3.4.

---

## 5. Budget and Invocation Gates

Checked deterministically by the Supervisor **before** each agent invocation, using
`policies\BUDGET_POLICY.json` and the counters in `STATUS.json`:

| Gate | Condition to proceed | On failure |
| --- | --- | --- |
| Worker invocation | `worker_calls < max_worker_calls` | `HUMAN_REQUIRED` / `budget_exhausted` |
| Reviewer invocation | `reviewer_calls < max_reviewer_calls` | `HUMAN_REQUIRED` / `budget_exhausted` |
| Correction | `correction_round < max_correction_rounds` | `HUMAN_REQUIRED` / `correction_limit_reached` |
| Tokens | observed tokens `< max_total_tokens` | `HUMAN_REQUIRED` / `budget_exhausted` |
| Runtime | elapsed minutes `< max_runtime_minutes` | `HUMAN_REQUIRED` / `budget_exhausted` |

Crossing `warning_tokens` is recorded but does not halt the run.

Counter rules:

- `worker_calls` increments on entry to `WORKER_RUNNING`;
- `reviewer_calls` increments on entry to `REVIEWING`, including a re-invocation under Section 3.4;
- counters are non-negative and monotonically increasing within a run;
- `updated_at` is rewritten on every `STATUS.json` write.

An agent may report consumption. An agent may not authorize additional budget.

---

## 6. Human Resumption

Execution leaves `HUMAN_REQUIRED` only through a recorded human action. The mapping is fixed:

| Human action | Transition | Notes |
| --- | --- | --- |
| `APPROVE` | `HUMAN_REQUIRED -> APPROVED` | Permitted only when the escalation occurred at or after `REVIEWING` and the work is already implemented and validated. Publication then proceeds through `APPROVED -> PUBLISHING` under Git policy. |
| `REJECT` | `HUMAN_REQUIRED -> FAILED` | Terminal. |
| `MODIFY_SCOPE` | `HUMAN_REQUIRED -> PLANNING` | Requires an updated `TASK.json`. |
| `INCREASE_BUDGET` | `HUMAN_REQUIRED -> PLANNING` | Requires an updated budget for the run. |
| `RETRY` | `HUMAN_REQUIRED -> PLANNING` | Re-plans from the current repository state. |
| `CANCEL` | `HUMAN_REQUIRED -> CANCELLED` | Terminal. |

Re-entry is at `PLANNING` rather than at the state where the run halted, because `STATUS.json` has
no field recording a resume point. See ARCHITECTURAL NOTES. Counters are **not** reset by any of
these actions.

Triggers and definitions for each action are in `ESCALATION_POLICY.md`.

---

## 7. Publication Constraints

Publication is a deterministic operation, not an agent decision. Reaching `APPROVED` authorizes only
the operations Git policy permits.

The Supervisor refuses to enter `PUBLISHING`, and escalates to `HUMAN_REQUIRED`, when any of the
following holds:

- the target branch is a protected branch;
- a force push would be required;
- a merge would be required;
- changed files fall outside `allowed_paths`, or touch `forbidden_paths`;
- the security validator flagged the change;
- the run is not in `APPROVED`.

Automatic merge is not implemented and is not permitted. `PUBLISHING` may create or update a branch
and a pull request only.

---

## 8. Invariants Restated

This policy does not relax any invariant in section 8 of the guidelines. In particular:

```text
NO_DIRECT_PUSH_TO_PROTECTED_BRANCH
NO_FORCE_PUSH
NO_AUTOMATIC_MERGE
NO_UNBOUNDED_AGENT_LOOPS
MAX_CORRECTION_ROUNDS = 1
BUDGET_ENFORCED_OUTSIDE_THE_AGENT
AGENTS_CANNOT_SELF_ELEVATE_PRIVILEGES
OUT_OF_SCOPE_CHANGES_CANNOT_BE_SILENTLY_PUBLISHED
EVERY_RUN_HAS_AN_AUDIT_TRAIL
```

---

## ARCHITECTURAL NOTES

Open items recorded rather than silently decided:

1. `next_action: NONE` exists in `schemas\REVIEW.schema.json` but has no valid decision pairing.
   Either a use for it must be defined or it should be removed from the schema.
2. `STATUS.json` has no resume-point field, so all human resumptions re-enter at `PLANNING`. A
   `resume_state` field would allow precise resumption but requires a schema change.
3. "Protected branch" is not defined for this repository. Section 15 of the guidelines names `main`
   and `master`; the authoritative list belongs in `GIT_POLICY.md`.
4. Section 3.4 infers that `max_reviewer_calls = 3` accommodates two scheduled reviews plus one
   retry. This is an interpretation of a provisional number, not a stated rule.
5. Token accounting has no defined artifact. Section 5 of the guidelines mentions `USAGE.json`, but
   no schema exists for it, and `STATUS.json` carries only an optional `total_tokens` field.
