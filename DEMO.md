# Clippy Demo Guide

## Intro (30 seconds)

> "Hi everyone! I'm excited to show you **Clippy** - a macOS file organizer that uses trust-centered design. Instead of automatically moving files, Clippy lets you **review and approve** every action before execution. It's like having a personal file assistant that suggests changes but never acts without your permission."

---

## Demo Outline (5 minutes)

### 1. The Problem (30 sec)

- Show the messy demo folder (`~/Desktop/ClippyDemo`) with mixed files
- "We all have Downloads folders full of mixed files - PDFs, images, installers, documents..."

### 2. Scan & Discover (1 min)

- Select ClippyDemo folder in sidebar
- Click **Scan** in toolbar
- Show scan results with file counts
- "Clippy scans your folder and identifies all files"

### 3. Duplicates Detection (45 sec)

- Point out **Duplicates button** in toolbar (appears after scan)
- Click to show duplicates modal
- "Uses SHA256 hash to find truly identical files - not just same name or size"

### 4. Create Plan & Execute (1 min)

- Click **Create Plan** → Show preview of planned actions
- Click **Execute** → Files get organized into folders
- "Files moved to organized folders - but YOU approved first"

### 5. Undo (15 sec)

- Click **Undo** in toolbar → Files return to original locations
- "Made a mistake? One-click undo"

### 6. Rules - Enable/Disable All (30 sec)

- Go to **Rules** tab in sidebar
- Show the **Enable All / Disable All** toggle button
- Click to toggle all rules at once
- "Bulk control over all your rules with one click"

### 7. Drag-and-Drop Rule Creation (45 sec)

- Look for the banner: "Drop a file here to create a rule"
- Drag a file from Finder onto the Rules view
- Show banner highlights blue when dragging over
- Drop the file → Rule Editor opens with extension pre-filled
- "Creating rules is as easy as dragging a file"

---

## Key Selling Points

1. **Trust-Centered** - Always review before execution
2. **Hash-Based Duplicates** - SHA256 comparison finds true duplicates
3. **Drag-and-Drop Rules** - Easy rule creation from files
4. **Safe** - Undo any action instantly

---

# Clippy Internal Architecture

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Clippy App                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │   Scanner    │───▶│   Planner    │───▶│   Executor   │     │
│  │  (Discover)  │    │  (Plan)      │    │  (Execute)   │     │
│  └──────────────┘    └──────────────┘    └──────────────┘     │
│         │                   │                   │              │
│         ▼                   ▼                   ▼              │
│  ┌──────────────────────────────────────────────────────┐      │
│  │                   AppState (Central State)           │      │
│  │  • scanResult    • actionPlan    • executionLog     │      │
│  │  • rules         • undoEngine     • duplicateGroups  │      │
│  └──────────────────────────────────────────────────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Scanner (`FileScanner.swift`)
- Recursively scans folder directories
- Builds `FileDescriptor` for each file
- Supports cancellation
- Returns `ScanResult` with all files

### 2. Planner (`Planner.swift`)
- Takes scanned files + enabled rules
- Matches files against rule conditions
- Generates `ActionPlan` with `PlannedAction` items
- Each action links a file to an outcome

### 3. Executor (`ExecutionEngine.swift`)
- Executes the planned actions
- Records success/failure for each action
- Returns `ExecutionLog` for undo capability

### 4. Undo Engine (`UndoEngine.swift`)
- Uses execution log to reverse actions
- Moves files back to original locations
- One-click rollback

---

## Data Flow

```
1. User selects folder
       │
       ▼
2. Scanner scans folder → FileDescriptor[]
       │
       ▼
3. User clicks "Create Plan"
       │
       ▼
4. Planner matches files against Rules → ActionPlan
       │
       ▼
5. User reviews plan (Trust-Centered!)
       │
       ▼
6. User clicks "Execute"
       │
       ▼
7. Executor runs actions → ExecutionLog
       │
       ▼
8. (Optional) User clicks "Undo" → Files restored
```

---

## Duplicate Detection Algorithm

```
┌─────────────────────────────────────────────┐
│           Duplicate Detection Flow          │
└─────────────────────────────────────────────┘

Step 1: Group by Size
┌────────────────────────────────────────────┐
│ Files: [A, B, C, D, E]                     │
│ Sizes:  [1KB, 2KB, 1KB, 2KB, 1KB]         │
│                                            │
│ Group by size:                             │
│   1KB → [A, C, E]  (3 files)              │
│   2KB → [B, D]     (2 files)              │
└────────────────────────────────────────────┘
        │
        ▼
Step 2: Hash same-size files
┌────────────────────────────────────────────┐
│ For each group with >1 file:              │
│   Compute SHA256 hash                      │
│                                            │
│   1KB group:                               │
│     A: hash1, C: hash2, E: hash1          │
│     → Duplicates: [A, E] (same hash)       │
│                                            │
│   2KB group:                               │
│     B: hash3, D: hash4                     │
│     → No duplicates                        │
└────────────────────────────────────────────┘
        │
        ▼
Step 3: Return duplicate groups
┌────────────────────────────────────────────┐
│ duplicateGroups = [[A, E], ...]            │
└────────────────────────────────────────────┘
```

**Why this approach?**
- Fast: Size filtering eliminates most files
- Accurate: SHA256 finds truly identical content
- Memory efficient: Hashes in 1MB chunks

---

## Rule System

### Rule Structure
```swift
struct Rule {
    let name: String           // "Move PDFs to Archive"
    let conditions: [Condition] // [.fileExtension(is: "pdf")]
    let outcome: Outcome       // .move(to: ~/Documents/Archive)
    let isEnabled: Bool        // Can be toggled
}
```

### Condition Types
- `.fileExtension(is: "pdf")` - Match by extension
- `.fileName(contains: "Screenshot")` - Match by name
- `.fileSize(largerThan: 1_000_000)` - Match by size
- `.modifiedBefore(date:)` - Match by date
- `.isDirectory` - Match directories

### Outcome Types
- `.move(to: URL)` - Move file
- `.copy(to: URL)` - Copy file
- `.delete` - Delete file
- `.rename(prefix:, suffix:)` - Rename file

---

## Trust-Centered Design

```
┌─────────────────────────────────────────────────────────────┐
│                  Review Before Execute                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Scan     → Shows what files exist (read-only)          │
│       │                                                      │
│       ▼                                                      │
│  2. Plan     → Shows what WOULD happen (preview)           │
│       │                                                      │
│       ▼                                                      │
│  3. Execute  → User clicks confirm (user in control)      │
│       │                                                      │
│       ▼                                                      │
│  4. Undo     → Can reverse anytime                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Key Principle:** Clippy never acts automatically - every action requires user confirmation.

---

## Key Features Summary

| Feature | Description |
|---------|-------------|
| **Scanner** | Fast recursive folder scanning |
| **Rule Engine** | Flexible condition matching |
| **Planner** | Generates actionable plans |
| **Executor** | Safe file operations |
| **Undo** | Full reversal capability |
| **Duplicates** | SHA256 hash-based detection |
| **Drag-and-Drop** | Easy rule creation |
| **Enable/Disable All** | Bulk rule management |

---

## Files Structure

```
Sources/
├── Clippy/                    # Main App
│   ├── AppState.swift         # Central state management
│   ├── ContentView.swift      # Main UI
│   └── Navigation/
│       ├── OrganizeView.swift  # Scan/Plan/Execute UI
│       └── RulesView.swift    # Rule management
│
├── ClippyCore/                # Domain Models
│   ├── DomainModels.swift     # Rule, Action, Plan models
│   └── FileDescriptor.swift   # File metadata
│
└── ClippyEngine/              # Business Logic
    ├── FileScanner.swift      # Folder scanning
    ├── Planner.swift          # Action planning
    ├── ExecutionEngine.swift  # File operations
    └── UndoEngine.swift       # Undo functionality
```
