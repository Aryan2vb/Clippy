# File Organizer

A trust-centered macOS filesystem organization tool that makes changes explainable, reversible, and unsurprising.

## Overview

File Organizer is a macOS application designed with a fundamental principle: **correctness and trust take precedence over convenience and cleverness**. It helps users organize their files through declarative rules while maintaining complete transparency and reversibility of all operations.

### Core Philosophy

- **Explainable**: Every action has a human-readable reason
- **Reversible**: All changes can be safely undone
- **Unsurprising**: No automatic execution, no hidden behavior
- **Conservative**: When uncertain, skip and explain rather than guess

## Architecture

The system is built on strict separation of concerns with five core subsystems:

### 1. Scanner (`FileScanner.swift`)
- **Responsibility**: Read-only filesystem enumeration
- **Output**: Immutable `FileDescriptor` snapshots
- **Guarantees**: Best-effort, never blocks UI, produces evidence not truth

### 2. Planner (`Planner.swift`)
- **Responsibility**: Pure logic evaluation of files against rules
- **Output**: Immutable `ActionPlan` containing proposed changes
- **Guarantees**: Deterministic, conservative conflict resolution, explainable decisions

### 3. Execution Engine (`ExecutionEngine.swift`)
- **Responsibility**: Performs approved filesystem operations
- **Output**: Complete `ExecutionLog` of outcomes
- **Guarantees**: Obeys plan exactly, localized failure handling, never retries aggressively

### 4. Undo Engine (`UndoEngine.swift`)
- **Responsibility**: Reverses executed actions using logs
- **Output**: `UndoLog` recording restoration attempts
- **Guarantees**: Best-effort restoration, never worsens user state, skips when unsafe

### 5. Observer (`FileSystemObserver.swift`)
- **Responsibility**: Passive filesystem event monitoring via FSEvents
- **Output**: `FileSystemEvent` notifications
- **Guarantees**: Advisory only, never triggers execution, events are hints not facts

### Bridge Components

- **Scan Bridge** (`ScanBridge.swift`): Connects Observer events to staleness suggestions
- **UI Copy** (`UICopy.swift`): Centralized repository of user-facing strings

## System Contract

The system operates under a strict contract defined in `formalSystemContract.md`:

### Key Invariants

1. **No Unplanned Mutation**: Filesystem writes require explicit `ActionPlan` approval
2. **Observation Is Non-Causal**: Events never trigger automatic execution
3. **Reversibility Over Destruction**: "Delete" means "move to Trash", never permanent
4. **Undo Is Conservative**: Skips when restoration is unsafe
5. **Explanation Is Mandatory**: Every action and skip includes reasoning
6. **Stale Is Acceptable, Wrong Is Not**: System tolerates staleness but never guesses

### Responsibility Boundaries

| Subsystem      | Read FS | Write FS | Decide | Observe |
|----------------|---------|----------|--------|---------|
| Scanner        | ✓       | ✗        | ✗      | ✗       |
| Planner        | ✗       | ✗        | ✓      | ✗       |
| Executor       | ✗       | ✓        | ✗      | ✗       |
| Undo Engine    | ✗       | ✓        | ✗      | ✗       |
| Observer       | ✗       | ✗        | ✗      | ✓       |

Violating these boundaries is a contract breach.

## Domain Models

### Rules (`DomainModels.swift`)

Rules are declarative policies defining conditions and desired outcomes:

```swift
Rule(
    name: "Archive PDFs",
    description: "Move old PDF files to archive",
    conditions: [
        .fileExtension(is: "pdf"),
        .modifiedBefore(date: thirtyDaysAgo)
    ],
    outcome: .move(to: archiveURL)
)
```

### Conditions

- `fileExtension(is: String)`
- `fileName(contains: String)`
- `fileSize(largerThan: Int64)`
- `createdBefore(date: Date)`
- `modifiedBefore(date: Date)`
- `isDirectory`

### Outcomes

- `move(to: URL)` - Move to specified folder
- `copy(to: URL)` - Copy to specified folder
- `delete` - Move to system Trash (reversible)
- `rename(prefix: String?, suffix: String?)` - Rename with prefix/suffix
- `skip(reason: String)` - Explicitly do nothing

## Workflow

```
1. User selects folder
2. Scanner reads filesystem → [FileDescriptor]
3. User creates/enables Rules
4. Planner evaluates files against rules → ActionPlan
5. User reviews plan (with explanations)
6. User approves
7. Execution Engine executes → ExecutionLog
8. User can undo via UndoEngine ← ExecutionLog
```

### Observer Flow (Parallel)

```
FileSystem changes → FSEvents → Observer → ScanBridge → Staleness suggestion
                                                       → User decides to rescan
```

## UI Copy Guidelines

All user-facing text follows strict trust-preserving principles documented in `ui-copy-guide.md` and validated against `ui-copy-checklist.md`.

### Key Principles

1. **Epistemic Honesty**: Use uncertainty language (`may`, `might`, `could`)
2. **Intent vs Action Separation**: Plans use conditional language, results use past tense
3. **Explanation Completeness**: Every action includes "because..." reasoning
4. **Blame Direction**: Attribute failure to conditions, not mistakes
5. **Reversibility Signaling**: Never promise undo success
6. **Anxiety Management**: No urgency language, suggestions are optional
7. **Temporal Accuracy**: Use relative time, avoid absolute claims
8. **Minimalism**: Less is safer, one idea per sentence

### Example Copy

**Plan Preview:**
```
Proposed changes
Nothing will happen until you approve.

invoice.pdf → Archive/2024
Because it matched the rule "Archive PDFs older than 30 days".
```

**Execution Result:**
```
What happened

invoice.pdf
Moved to Archive/2024.

summary.pdf
Skipped because the file no longer existed.
```

## Building & Running

### Requirements

- macOS 13.0+
- Swift 5.9+
- Xcode 14.0+

### Build

```bash
swift build
```

### Run Examples

Each subsystem includes example usage functions:

```swift
// FileScanner example
await fileScannerExample()

// Planner example
plannerExample()

// Execution Engine example
executionExample()

// Undo Engine example
undoExample()

// Observer example
observerExample()

// Scan Bridge example
scanBridgeExample()
```

## Project Structure

```
Sources/
├── FileScannerApp.swift        # App entry point
├── ContentView.swift           # Main UI
├── DomainModels.swift          # Core data models (Rules, Plans, Actions)
├── FileDescriptor.swift        # Immutable file snapshot model
├── FileScanner.swift           # Filesystem enumeration engine
├── Planner.swift              # Rule evaluation logic
├── ExecutionEngine.swift      # Filesystem mutation executor
├── UndoEngine.swift           # Action reversal engine
├── FileSystemObserver.swift   # FSEvents monitoring
├── ScanBridge.swift           # Event → Staleness bridge
└── UICopy.swift               # User-facing text repository

Documentation/
├── formalSystemContract.md    # Non-negotiable system guarantees
├── ui-copy-guide.md          # Trust-preserving copy patterns
└── ui-copy-checklist.md      # 10-point copy validation
```

## Logging & Audit

All operations produce immutable, append-only logs:

- **ExecutionLog**: Records every filesystem operation attempt
- **UndoLog**: Records every restoration attempt
- **ScanResult**: Includes enumeration errors encountered

Logs are designed to be:
- Human-interpretable without code execution
- Complete records of intent and outcome
- Suitable for audit trails
- Serializable for persistence

## Safety Features

### Conflict Resolution

When multiple rules match a file with different outcomes, the Planner:
1. Detects the conflict
2. Skips the file
3. Explains: "Conflict! Multiple rules matched with different outcomes: [details]"

### Execution Safety

- Never overwrites existing files
- Creates parent directories as needed
- Logs all failures without aborting entire plan
- Handles permission errors gracefully

### Undo Safety

- Only attempts to reverse successful actions
- Checks filesystem state before restoration
- Skips when original location is occupied
- Explains every skip decision

## Failure Philosophy

The system explicitly prefers:

- **Skip** over guess
- **Explanation** over retry
- **Safety** over completeness
- **Predictability** over cleverness

Failures are expected and accepted. Surprises are not.

## Prohibited Behaviors

The following are forbidden by contract:

- Auto-execution triggered by filesystem events
- Silent overwrite of user files
- Automated permanent deletion
- Re-planning during execution
- Trusting filesystem events as truth
- Modifying files without logging

## Extension Guidelines

Future features must:

1. Preserve all system invariants
2. Respect subsystem boundaries
3. Degrade safely under failure
4. Remain explainable months later
5. Not increase surprise

If a feature cannot meet these conditions, it must not be built.

## Contributing

### Code Review Checklist

Before submitting changes:

1. Does this violate any system contract invariant?
2. Does this cross subsystem responsibility boundaries?
3. Could this cause filesystem mutation without user approval?
4. Are all user-facing strings validated against the UI copy checklist?
5. Does this gracefully handle missing/changed files?
6. Are logs complete and human-readable?

### UI Copy Review

All user-facing text must pass the 10-point checklist in `ui-copy-checklist.md`:

1. ✓ Epistemic Honesty
2. ✓ Intent vs Action Separation
3. ✓ Explanation Completeness
4. ✓ Blame Direction
5. ✓ Reversibility Signaling
6. ✓ Anxiety Management
7. ✓ Consistency with System Contract
8. ✓ Temporal Accuracy
9. ✓ Minimalism
10. ✓ **Final Kill Test**: "If this turns out to be wrong, would I feel misled?"

## Group Members

### Kalash kumari thakur
### Soniya Malviya
### Aryan Soni
