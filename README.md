# File Organizer

A trust-centered macOS filesystem organization tool that makes changes explainable, reversible, and unsurprising.

## Overview

File Organizer is a macOS application designed with a fundamental principle: **correctness and trust take precedence over convenience and cleverness**. It helps users organize their files through declarative rules while maintaining complete transparency and reversibility of all operations.

### Core Philosophy

- **Explainable**: Every action has a human-readable reason
- **Reversible**: All changes can be safely undone
- **Unsurprising**: No automatic execution, no hidden behavior
- **Conservative**: When uncertain, skip and explain rather than guess

## Features

- **File Scanning**: Traverse directories and discover files with metadata
- **Rule-Based Organization**: Define declarative rules for file management
- **Real-time Monitoring**: Watch filesystem changes with FSEvents
- **Undo Support**: Full undo capability for all operations
- **Modern UI**: Clean SwiftUI interface for file management

## Requirements

- macOS 13.0 or later
- Swift 5.9+
- Xcode 15.0+

## Building

### Using Swift Package Manager

```bash
# Build the project
swift build

# Build release version
swift build -c release

# Run the application
swift run FileScannerApp
```

### Using Xcode

1. Open `Package.swift` in Xcode
2. Select the `FileScannerApp` scheme
3. Press ⌘R to build and run

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

## Project Structure

```
Sources/
├── FileScannerApp.swift        # App entry point
├── ContentView.swift           # Main UI
├── DomainModels.swift          # Core data models (Rules, Plans, Actions)
├── FileDescriptor.swift        # Immutable file snapshot model
├── FileScanner.swift           # Filesystem enumeration engine
├── Planner.swift               # Rule evaluation logic
├── ExecutionEngine.swift       # Filesystem mutation executor
├── UndoEngine.swift            # Action reversal engine
├── FileSystemObserver.swift    # FSEvents monitoring
├── ScanBridge.swift            # Event → Staleness bridge
└── UICopy.swift                # User-facing text repository

docs/
└── formalSystemContract.md     # Non-negotiable system guarantees
```

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

## Rules

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

## System Contract

The system operates under a strict contract defined in `docs/formalSystemContract.md`:

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

## Safety Features

### Conflict Resolution

When multiple rules match a file with different outcomes, the Planner:
1. Detects the conflict
2. Skips the file
3. Explains: "Conflict! Multiple rules matched with different outcomes"

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

## License

This project is for educational purposes.

## Group Members

- Kalash Kumari Thakur
- Soniya Malviya
- Aryan Soni
