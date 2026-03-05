# Clippy — Merged Fix Prompt

## Based on: Kimi K2.5 Audit + Claude Opus 4.6 Audit (Cross-Referenced)

> Send this entire prompt to your AI coding assistant.
> Fixes are ordered: Critical → High → Medium → Low.
> Do NOT add features. Do NOT refactor working code beyond what is listed.

---

## HOW THE TWO AUDITS COMPARE

Before fixing, understand what each model caught that the other missed:

| Finding                                    | Kimi K2.5      | Opus 4.6                                  | Verdict                                                  |
| ------------------------------------------ | -------------- | ----------------------------------------- | -------------------------------------------------------- |
| Duplicate folder selector                  | ✅ (2 places)  | ✅ (3 places — more accurate)             | Opus found the extra "Change Folder" inside DropZoneView |
| @MainActor / DispatchQueue bug             | ✅ (mentioned) | ✅ (deep, with diff)                      | Opus gave exact before/after code                        |
| "Permanently deleted" lie in copy          | ❌ missed      | ✅ CRITICAL                               | Opus only — this is a trust model violation              |
| Duplicate startScan() with divergent logic | ❌ missed      | ✅ CRITICAL                               | Opus only — silent data quality bug                      |
| RuleValidator.validate() never called      | ❌ missed      | ✅ HIGH                                   | Opus only — dead security code                           |
| sanitizePath() bypassable + never called   | ❌ missed      | ✅ HIGH                                   | Opus only                                                |
| Rename appends suffix after extension      | ❌ missed      | ✅ MEDIUM                                 | Opus only — produces broken filenames                    |
| Cancelled scan shown as complete           | ❌ missed      | ✅ HIGH                                   | Opus only — violates system contract                     |
| N×disk writes on enableAllRules()          | ❌ missed      | ✅ HIGH                                   | Opus only                                                |
| Example functions ship in binary           | ❌ missed      | ✅ LOW                                    | Opus only — contains hardcoded paths                     |
| Force unwrap in FSEvents                   | ✅ CRITICAL    | ❌ missed (found observerExample instead) | Kimi only                                                |
| Path prefix string matching bypass         | ✅ HIGH        | ✅ HIGH (different angle)                 | Both found it, Opus more accurate                        |
| ScanBridge delegate never set              | ✅ MEDIUM      | ❌ missed                                 | Kimi only                                                |
| HistoryManager wrong folder name           | ✅ HIGH        | ✅ MEDIUM                                 | Both found it                                            |
| Undo button colored red (wrong)            | ✅ LOW         | ✅ MEDIUM                                 | Both found it                                            |
| Delete color inconsistency red vs orange   | ❌ missed      | ✅ MEDIUM                                 | Opus only                                                |
| Conflict detection via string matching     | ✅ mentioned   | ✅ HIGH (with fix)                        | Opus gave better fix                                     |
| Dead legacy OutcomeBadge struct            | ❌ missed      | ✅ MEDIUM                                 | Opus only                                                |
| Drop zone always returns true              | ❌ missed      | ✅ LOW                                    | Opus only                                                |

**Conclusion:** Opus 4.6 found significantly more issues, especially in code correctness
(rename bug, cancelled scan, dead validation code, the "permanently deleted" lie).
Kimi found the FSEvents force unwrap and ScanBridge delegate gap.
Use BOTH — this prompt merges everything.

---

## 🔴 CRITICAL FIXES

---

### CRITICAL-1: "Permanently Deleted" Copy Contradicts the Engine

**File:** `Sources/Core/DomainModels.swift:239`
**Found by:** Opus 4.6 only

This is a TRUST MODEL VIOLATION. The UI tells the user their files will be
"permanently deleted" but `ExecutionEngine.performDelete()` uses `trashItem()`.
This is a lie that damages user trust and violates the system contract's
"Explanation Is Mandatory" guarantee.

```diff
// DomainModels.swift → ActionPlan.userFriendlySummary
- if deleteCount > 0 { lines.append("• \(deleteCount) will be permanently deleted.") }
+ if deleteCount > 0 { lines.append("• \(deleteCount) will be moved to Trash.") }
```

Also search the entire codebase for the word "permanently" and "delete" in
any user-facing string (UICopy.swift, inline Text() calls, alert messages).
Replace ALL occurrences with "Move to Trash" or "moved to Trash".
The word "permanently" must not appear anywhere in user-facing copy.

---

### CRITICAL-2: Force Unwrap Crash in FSEvents Callback

**File:** `Sources/Engine/FileSystemObserver.swift:236`
**Found by:** Kimi K2.5 only

```diff
- let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
+ guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
+     .takeUnretainedValue() as? [String] else {
+     delegate?.observer(self, didEncounterError: .unknown("Failed to parse FSEvent paths"))
+     return
+ }
```

---

### CRITICAL-3: Duplicate startScan() With Divergent Duplicate Detection Logic

**File:** `Sources/Navigation/OrganizeView.swift:142-167 AND 446-471`
**Found by:** Opus 4.6 only

Two different `startScan()` functions exist in the same file:

- `OrganizeView.startScan()` uses SHA256 hash-based duplicate detection (accurate)
- `ReadyToScanView.startScan()` uses file-size-only grouping (inaccurate — false positives)

This means clicking "Scan" in the toolbar gives different results than clicking
"Review changes by scanning" in the empty state. Silent data quality divergence.

**Fix:** Delete `ReadyToScanView`'s private `startScan()` entirely.
Have it call the parent's `startScan()` via a passed closure or binding instead:

```swift
// ReadyToScanView should NOT have its own startScan()
// Pass it from OrganizeView:
ReadyToScanView(onStartScan: startScan)
//              ↑ single source of truth
```

Also consolidate `createPlan()`, `executePlan()`, and `performUndo()` the same way —
each of these has two implementations. Move all four workflow functions to `AppState`
as methods, then have every view call `appState.startScan()`, `appState.createPlan()` etc.

---

### CRITICAL-4: @MainActor Violations — DispatchQueue Pattern

**File:** `Sources/Navigation/OrganizeView.swift:219-247 AND 782-795 AND 1039-1050`
**Found by:** Both models (Opus gave exact diff)

`AppState` is `@MainActor` but mutations are happening inside `DispatchQueue.global`
closures. This is a data race. Under Swift 6 strict concurrency this will not compile.

Replace ALL four occurrences of this pattern:

```diff
- DispatchQueue.global(qos: .userInitiated).async {
-     let log = executor.execute(plan: plan)
-     DispatchQueue.main.async {
-         appState.executionLog = log
-         appState.actionPlan = nil
-         appState.isExecuting = false
-     }
- }
+ Task.detached(priority: .userInitiated) {
+     let log = executor.execute(plan: plan)
+     await MainActor.run {
+         appState.executionLog = log
+         appState.actionPlan = nil
+         appState.isExecuting = false
+     }
+ }
```

Apply to: `OrganizeView.executePlan()`, `OrganizeView.performUndo()`,
`PlanPreviewView.executePlan()`, `ExecutionResultsView.performUndo()`.
After CRITICAL-3 is done, there will only be two (consolidated into AppState).

---

### CRITICAL-5: Cancelled Scan Presented as Complete Data

**File:** `Sources/Navigation/OrganizeView.swift:156`
**Found by:** Opus 4.6 only

When a scan is cancelled, the partial result is still set as `scanResult`
and shown to the user as a complete file list. The user can then click
"Create Plan" on incomplete data. This violates: _"Stale Is Acceptable, Wrong Is Not"_.

```swift
// In startScan(), after scan completes:
await MainActor.run {
    if result.wasCancelled {
        appState.scanResult = nil          // Clear — do NOT show partial data
        appState.cancellationMessage = "Scan was cancelled. No files were loaded."
    } else {
        appState.scanResult = result       // Only set on full completion
    }
    appState.isScanning = false
}
```

Add `cancellationMessage: String?` to `AppState` and display it in the
empty state view when set.

---

## 🟠 HIGH FIXES

---

### HIGH-1: RuleValidator.validate() Is Dead Code — Never Called

**File:** `Sources/Core/DomainModels.swift:61-132` and
`Sources/Navigation/RulesView.swift` (saveRule function)
**Found by:** Opus 4.6 only

A full security validation function exists but is never invoked.
Rules are saved directly without any validation. All security checks are dead.

```swift
// In RuleEditorView.saveRule():
// BEFORE:
appState.rules.append(newRule)

// AFTER:
let validationResult = RuleValidator.validate(newRule)
switch validationResult {
case .valid:
    appState.rules.append(newRule)
case .invalid(let reason):
    validationError = reason   // Show inline error in the sheet
    return
}
```

Add `@State var validationError: String?` to `RuleEditorView` and show it
as an inline `.foregroundColor(.red)` text below the Save button.

---

### HIGH-2: sanitizePath() Is Bypassable AND Never Called

**File:** `Sources/Core/DomainModels.swift:135-158`
**Found by:** Opus 4.6 only

Two problems: (1) the sanitizer has a double-encoding bypass via `"..././"` input,
and (2) it's never called anywhere.

Fix the sanitizer AND wire it up:

```swift
// Replace the while loop with standardizingPath which handles this correctly:
static func sanitizePath(_ path: String) -> String {
    var result = path.trimmingCharacters(in: .whitespaces)
    result = (result as NSString).standardizingPath  // Handles ../ correctly
    // Expand ~ if present
    if result.hasPrefix("~") {
        result = (result as NSString).expandingTildeInPath
    }
    return result
}
```

Then call it inside `RuleValidator.validate()` before path checks:

```swift
let sanitized = sanitizePath(destinationPath)
// validate sanitized, not raw path
```

---

### HIGH-3: Path Validation — Overly Broad "/Users/" Prefix

**Files:** `Sources/Navigation/RulesView.swift:763-769` and
`Sources/Engine/ExecutionEngine.swift:91-103` and
`Sources/Core/DomainModels.swift:47-51`
**Found by:** Both models (different angles)

Three specific fixes:

**A) RulesView.swift — isPathAllowed() uses "/Users/" (too broad):**

```diff
- allowedPrefixes: ["/Users/", NSHomeDirectory()]
+ allowedPrefixes: [NSHomeDirectory()]
```

`/Users/` allows targeting any other user's home directory.

**B) DomainModels.swift — blockedPaths must include symlink targets:**

```swift
private static let blockedPaths: [String] = [
    "/System", "/usr/bin", "/usr/sbin", "/bin", "/sbin",
    "/etc", "/var", "/private", "/private/var", "/private/etc",
    "/dev", "/Applications",
    (NSHomeDirectory() + "/Library" as NSString).standardizingPath
].map { ($0 as NSString).standardizingPath }
```

**C) ExecutionEngine.swift — fix isPathWithinSandbox prefix boundary check:**

```swift
private func isPathWithinSandbox(_ path: String) -> Bool {
    let resolved = (path as NSString).standardizingPath
    return allowedSandboxPaths.contains { allowed in
        let standardized = (allowed as NSString).standardizingPath
        guard resolved.hasPrefix(standardized) else { return false }
        let remainder = resolved.dropFirst(standardized.count)
        return remainder.isEmpty || remainder.first == "/"
        // Prevents "/Users/aryansoni/DocumentsMalicious" matching "/Users/aryansoni/Documents"
    }
}
```

---

### HIGH-4: Conflict Detection Uses Fragile String Matching

**File:** `Sources/Navigation/OrganizeView.swift:133-138 AND 658-659`
**Found by:** Both models (Opus gave the correct fix)

`hasUnresolvedConflicts` and `conflictActions` both check
`action.reason.lowercased().contains("conflict")`. This breaks if any rule
name contains the word "conflict", or if Planner ever changes its message.

**Fix:** Add a first-class `isConflict` property to `PlannedAction` in DomainModels.swift:

```swift
// In DomainModels.swift:
struct PlannedAction {
    // ... existing fields ...
    let isConflict: Bool    // ADD THIS
}
```

In `Planner.swift`, set `isConflict: true` when generating conflict skip actions.

Then update the detection:

```swift
// OrganizeView:
var hasUnresolvedConflicts: Bool {
    appState.actionPlan?.actions.contains { $0.isConflict } ?? false
}
```

---

### HIGH-5: N×Disk Writes on enableAllRules() / disableAllRules()

**File:** `Sources/ContentView.swift:85-114`
**Found by:** Opus 4.6 only

Each `rules[i] = ...` in the loop triggers `didSet` → `saveRules()`.
40 rules = 40 JSON encodes + 40 disk writes for one button click.

```swift
// BEFORE (in AppState):
func enableAllRules() {
    for i in rules.indices {
        rules[i] = Rule(/* enabled: true */)  // triggers didSet 40 times
    }
}

// AFTER — batch update, single save:
func enableAllRules() {
    var updated = rules
    for i in updated.indices {
        updated[i] = updated[i].withEnabled(true)
    }
    rules = updated  // single assignment → single didSet → single saveRules()
}
```

Add `func withEnabled(_ enabled: Bool) -> Rule` to the `Rule` struct.

---

### HIGH-6: Tab Switching Allowed During Execution

**File:** `Sources/ContentView.swift` (sidebar)
**Found by:** Kimi K2.5

```swift
// AppState — add:
@Published var isExecuting: Bool = false

// Sidebar tab list:
ForEach(SidebarTab.allCases) { tab in
    // ...
}
.disabled(appState.isExecuting)

// Set isExecuting = true before execution, false after (in CRITICAL-4 fix above)
```

---

### HIGH-7: ScanBridge Delegate Never Connected

**File:** `Sources/ContentView.swift` (AppState init)
**Found by:** Kimi K2.5 only

```swift
// In AppState.init():
self.scanBridge = ScanBridge()
self.scanBridge.delegate = self  // ADD THIS

// Ensure AppState conforms to ScanBridgeDelegate and
// implements required methods to update stalenessState
```

---

### HIGH-8: Execute Button Has No Confirmation — Bypasses Review Step

**File:** `Sources/Navigation/OrganizeView.swift:94-100`
**Found by:** Opus 4.6

The toolbar "Execute" button calls `executePlan()` directly with no confirmation.
This bypasses `PlanPreviewView` entirely if the user clicks the toolbar button
while a plan is loaded.

Two fixes required:

**A)** Add confirmation alert to the toolbar Execute button:

```swift
Button("Execute") { showExecuteConfirmation = true }
.confirmationDialog(
    "Execute \(appState.actionPlan?.actions.count ?? 0) actions?",
    isPresented: $showExecuteConfirmation,
    titleVisibility: .visible
) {
    Button("Execute", role: .destructive) { executePlan() }
    Button("Cancel", role: .cancel) { }
}
```

**B)** Add guard in `executePlan()` as a belt-and-suspenders check:

```swift
func executePlan() {
    guard let plan = appState.actionPlan else { return }
    guard !hasUnresolvedConflicts else {
        appState.errorMessage = "Resolve all conflicts before executing."
        return
    }
    // proceed...
}
```

---

## 🟡 MEDIUM FIXES

---

### MEDIUM-1: Rename Bug — Suffix Appended After File Extension

**File:** `Sources/Engine/Planner.swift:146-151`
**Found by:** Opus 4.6 only — this produces BROKEN filenames

`report.pdf` + suffix `_old` → `report.pdf_old` (wrong)
Should produce: `report_old.pdf`

```swift
// BEFORE:
if let s = suffix { name = name + s }

// AFTER:
if let s = suffix {
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    name = base + s + (ext.isEmpty ? "" : "." + ext)
}
```

---

### MEDIUM-2: Remove Duplicate Folder Selector from Sidebar

**File:** `Sources/ContentView.swift:513-541`
**Found by:** Both models (Opus found it exists in 3 places, not 2)

Remove `FolderSelectorButton` from the sidebar completely.
Replace with read-only current folder display:

```swift
// REMOVE: FolderSelectorButton(...)

// ADD:
if let folder = appState.selectedFolderURL {
    HStack(spacing: 6) {
        Image(systemName: "folder.fill")
            .foregroundColor(.secondary)
            .font(.caption)
        Text(folder.lastPathComponent)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
}
```

The canonical folder selector is `DropZoneView` in `OrganizeView` only.
Also note: `DropZoneView` internal "Change Folder" button calls `onFolderSelected`
which resets state — verify this doesn't double-reset after removing the sidebar button.

---

### MEDIUM-3: History Stored in Wrong App Support Folder

**File:** `Sources/HistoryManager.swift:494`
**Found by:** Both models

```diff
- let appFolder = appSupport.appendingPathComponent("FileScannerApp", isDirectory: true)
+ let appFolder = appSupport.appendingPathComponent("Clippy", isDirectory: true)
```

Also verify `Sources/ContentView.swift:136` uses `"Clippy"` — both MUST match.

---

### MEDIUM-4: HistoryManager.undoSession() Marks Failed Undos as "Restored"

**File:** `Sources/HistoryManager.swift:246-264`
**Found by:** Opus 4.6 only

Currently marks EVERY item as "Undone - restored to original location" regardless
of whether the undo actually succeeded. A failed undo is logged as success.

```swift
// After each individual undo attempt, check the result:
for item in session.items {
    let undoResult = undoEngine.undoSingleAction(item)
    let outcome: HistoryOutcome = undoResult.success
        ? .restored
        : .failed(reason: undoResult.reason ?? "Undo failed")
    // Record actual outcome, not assumed success
}
```

---

### MEDIUM-5: Scan Toolbar Button Enabled While executionLog Exists

**File:** `Sources/Navigation/OrganizeView.swift` (toolbar Scan button)
**Found by:** Opus 4.6

The Scan button is not disabled when `executionLog != nil`.
User can re-scan while viewing results — clears scan data but leaves
execution log visible — confusing mixed state.

```swift
Button { startScan() } label: { ... }
.disabled(
    appState.selectedFolderURL == nil ||
    appState.isScanning ||
    appState.isExecuting ||
    appState.executionLog != nil   // ADD THIS
)
```

---

### MEDIUM-6: Delete Color Inconsistency — Red vs Orange

**Files:** `OrganizeView.swift:883`, `OrganizeView.swift:808`,
`ActionChip.swift:39`, `HistoryManager.swift:65`
**Found by:** Opus 4.6 only

Delete is `.red` in the plan view, `.orange` in summary badges,
and `"orange"` in history. Pick one and apply everywhere.

Decision: Use `Color(NSColor.systemRed)` for all delete/trash actions.
Update `HistoryActionType.deleted.color` to `"red"` as well.
Delete `PlanSummaryBadges` entirely (it's already marked "Legacy compat").

---

### MEDIUM-7: Undo Button Styled as Destructive (Red) — Wrong Semantics

**File:** `Sources/Navigation/OrganizeView.swift:986-994`
**Found by:** Both models

Undo is a _restorative_ action, not destructive. Red makes users afraid to click it.

```diff
- .buttonStyle(.borderedProminent)
- .tint(.red)
+ .buttonStyle(.borderedProminent)
+ // No tint override — use default blue accent
```

---

### MEDIUM-8: historyFileURL Has Side Effects in Computed Getter

**File:** `Sources/HistoryManager.swift:491-509`
**Found by:** Opus 4.6

Directory creation inside a `get` property is a design smell.
Move to lazy initialization:

```swift
private lazy var historyFileURL: URL = {
    let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let appFolder = appSupport.appendingPathComponent("Clippy", isDirectory: true)
    try? FileManager.default.createDirectory(at: appFolder,
        withIntermediateDirectories: true)
    return appFolder.appendingPathComponent("history.json")
}()
```

---

### MEDIUM-9: ConflictWarningRow Has Redundant Warning Indicators

**File:** `Sources/Components/ConflictWarningRow.swift:80-81`
**Found by:** Opus 4.6

Both SF Symbol AND emoji warning triangle shown simultaneously:

```diff
Image(systemName: "exclamationmark.triangle.fill")
- Text("⚠️ Conflicts")
+ Text("Conflicts")
```

---

### MEDIUM-10: Staleness State Not Reset on Folder Change

**File:** `Sources/ContentView.swift` (folder change handler)
**Found by:** Kimi K2.5

In the folder selection handler, reset ALL derived state:

```swift
appState.scanResult = nil
appState.actionPlan = nil
appState.executionLog = nil
appState.stalenessState = nil     // ADD THIS
appState.cancellationMessage = nil
```

---

## 🟢 LOW FIXES

---

### LOW-1: Remove Example Functions from Production Binary

**Files:** `ExecutionEngine.swift:410-509`, `UndoEngine.swift:234-294`,
`Planner.swift:184-229`, `ScanBridge.swift:281-316`,
`FileSystemObserver.swift:247-281`, `DomainModels.swift:248-280`
**Found by:** Opus 4.6 only

These contain hardcoded paths like `/Users/aryansoni/Downloads/` and
perform real filesystem operations. Delete all of them or move to a
`#if DEBUG` block or a separate test target.

```swift
// Wrap each with:
#if DEBUG
func executionExample() { ... }
#endif
```

---

### LOW-2: Delete Dead/Legacy Code

**Found by:** Opus 4.6

Delete these unused structs entirely — they are never instantiated:

- `OutcomeBadge` in `RulesView.swift:357-384` (marked "legacy", replaced by `OutcomeChipView`)
- `EmptyFolderStateView` in `OrganizeView.swift:401-409`
- `SearchEmptyStateView` in `ContentView.swift:1353-1372`
- `NoSearchResultsView` in `ContentView.swift:1374-1393`
- `FilterChip` in `ContentView.swift:1333-1351` (replaced by `ModernFilterChip`)
- `StatBadge` in `OrganizeView.swift:378-397`
- `PlanSummaryBadges` in `OrganizeView.swift:798-812` (marked "Legacy compat")
- Unused variable `updatedItem` in `HistoryManager.swift:438`

---

### LOW-3: Add Keyboard Shortcuts to Primary Workflow Actions

**File:** `Sources/Navigation/OrganizeView.swift`
**Found by:** Both models

```swift
Button { startScan() } label: { Label("Scan", systemImage: "magnifyingglass") }
    .keyboardShortcut("r", modifiers: .command)
    .help("Scan selected folder (⌘R)")

Button { createPlan() } label: { Label("Evaluate Rules", systemImage: "list.bullet.clipboard") }
    .keyboardShortcut("e", modifiers: [.command, .shift])
    .help("Evaluate rules against scanned files (⌘⇧E)")

Button { showExecuteConfirmation = true } label: { Label("Execute", systemImage: "play.fill") }
    .keyboardShortcut(.return, modifiers: .command)
    .help("Execute the approved action plan (⌘↩)")
```

Undo already has `⌘Z` as a system standard — wire it up:

```swift
Button { performUndo() } label: { ... }
    .keyboardShortcut("z", modifiers: .command)
```

---

### LOW-4: DropZone Returns true Before Validating Drop is a Folder

**File:** `Sources/Components/DropZoneView.swift:77-80`
**Found by:** Opus 4.6

```swift
// BEFORE:
.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
    handleDrop(providers: providers)
    return true  // always accepts, even files (not folders)
}

// AFTER:
.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
    // Return false for non-folders after validation
    // Use validateDrop to check UTType before accepting
    handleDrop(providers: providers)
    return true  // Keep true for now but show error if not folder
    // In handleDrop: if dropped item is not a directory, set an error message
}
```

In `handleDrop()`, after resolving the URL:

```swift
var isDir: ObjCBool = false
FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
guard isDir.boolValue else {
    dropErrorMessage = "Please drop a folder, not a file."
    return
}
```

---

## VERIFICATION CHECKLIST

After all fixes, verify:

- [ ] Zero instances of "permanently deleted" or "permanently" in user-facing copy
- [ ] Zero force unwraps (`!`) in `FileSystemObserver.swift`
- [ ] `startScan()`, `createPlan()`, `executePlan()`, `performUndo()` exist ONCE each (in AppState)
- [ ] No `DispatchQueue.global` + `DispatchQueue.main.async` pattern anywhere — replaced with `Task.detached` + `await MainActor.run`
- [ ] Cancelling a scan does NOT show partial results
- [ ] `RuleValidator.validate()` is called before every `rules.append()`
- [ ] Rename with suffix produces `file_old.pdf` not `file.pdf_old`
- [ ] Enable/Disable all rules triggers exactly ONE disk write, not N
- [ ] Sidebar shows current folder name only — no folder selector button
- [ ] Execute button (toolbar) shows confirmation dialog before executing
- [ ] Tab switching is disabled during execution (`appState.isExecuting`)
- [ ] `ScanBridge.delegate` is set in `AppState.init()`
- [ ] Both `HistoryManager` and `AppState` use `"Clippy"` folder name
- [ ] Undo button is NOT red — uses default blue accent
- [ ] Delete color is consistent (`systemRed`) across plan view, badges, and history
- [ ] All example functions are removed or wrapped in `#if DEBUG`
- [ ] All dead/legacy view structs are deleted
- [ ] App builds with zero warnings under Swift strict concurrency

```

```
