File Organizer System Contract

(macOS user-space filesystem subsystem)

0. Purpose of This Contract

This document defines the non-negotiable guarantees, boundaries, and failure philosophy of the system.

Any future feature, refactor, optimization, or UI change must comply with this contract.

If a proposed change violates this contract, the change is invalid — even if it “works.”

Correctness and trust take precedence over convenience and cleverness.

1. Core System Goal

The system exists to:

Make filesystem changes that are explainable, reversible, and unsurprising to the user.

The system does not exist to:

maximize automation

enforce opinions

act autonomously without user understanding

2. Fundamental Assumptions (Reality Model)

The system assumes the following truths about the environment:

The filesystem is mutable, hostile, and inconsistent

Files may disappear, change, or reappear at any time

Permissions may be revoked without notice

Filesystem events are unreliable signals, not facts

Perfect knowledge of the filesystem is impossible

All design choices flow from these assumptions.

3. System Invariants (Must Always Hold)

These invariants are absolute.

3.1 No Unplanned Mutation

No filesystem write may occur without an explicit ActionPlan

Execution must follow the plan exactly

No “helpful” adjustments during execution are allowed

3.2 Observation Is Non-Causal

Filesystem observation never triggers execution

Events do not imply intent

Events may only inform awareness or prompt user action

3.3 Reversibility Over Destruction

All automated destructive actions must be reversible

“Delete” means “move to Trash”

Permanent deletion is never automated

3.4 Undo Is Conservative

Undo never overwrites existing files

Undo skips when restoration is unsafe

Undo explains refusal rather than forcing outcomes

3.5 Explanation Is Mandatory

Every planned action has a human-readable reason

Every execution failure is logged with explanation

Silent failure is forbidden

3.6 Stale Is Acceptable, Wrong Is Not

Stale data is tolerated

Guessing is not

When uncertain, the system must skip and explain

4. Responsibility Boundaries (Hard Separation)

Each subsystem has exclusive authority over specific responsibilities.

Subsystem Read FS Write FS Decide Observe
Scanner ✓ ✗ ✗ ✗
Planner ✗ ✗ ✓ ✗
Executor ✗ ✓ ✗ ✗
Undo Engine ✗ ✓ ✗ ✗
Observer ✗ ✗ ✗ ✓

Violating these boundaries is a contract breach.

5. Subsystem Contracts
   5.1 Scanner Contract

Read-only

Best-effort enumeration

Produces evidence, not truth

Never blocks the UI

Never assumes stability

5.2 Planner Contract

Pure logic

Deterministic for identical inputs

Conservative conflict resolution

Produces intent, not actions

Explains every decision

5.3 Execution Engine Contract

Obeys the plan exactly

Executes actions independently

Failure of one action does not abort others

Logs every outcome

Never retries aggressively

5.4 Undo Engine Contract

Operates only on execution logs

Idempotent by design

Never worsens user state

Skips safely when uncertain

Explains all skips

5.5 Observer Contract

Passive

No deduplication guarantees

No state authority

No execution triggers

Events are advisory only

6. Logging & Audit Guarantees

The system guarantees:

Logs are append-only

Logs are immutable records of intent and outcome

Logs are human-interpretable without code execution

Logs may be incomplete, but never misleading

Logs are documents, not debug output.

7. Failure Philosophy

The system explicitly prefers:

skip over guess

explanation over retry

safety over completeness

predictability over cleverness

Failures are expected and accepted.

Surprises are not.

8. Idempotence Guarantees

The system guarantees:

Execution will not repeat effects on re-run

Undo can be run multiple times safely

Observation noise does not accumulate damage

Repeated operations must degrade gracefully.

9. Prohibited Behaviors (Never Allowed)

The following actions are forbidden:

Auto-execution triggered by filesystem events

Silent overwrite of user files

Automated permanent deletion

Re-planning during execution

Trusting filesystem events as truth

Modifying files without logging

Any feature requiring these behaviors violates the contract.

10. Extension Rules (Future Work)

Future features may be added only if they:

Preserve all invariants

Respect subsystem boundaries

Degrade safely under failure

Remain explainable months later

Do not increase surprise

If a feature cannot meet these conditions, it must not be built.

11. Closing Statement

This system does not aim to be clever.

It aims to be trustworthy.

Trust is achieved not by preventing failure,
but by making failure understandable, reversible, and contained.

This contract exists to protect that trust —
from the filesystem, from users, and from ourselves.
