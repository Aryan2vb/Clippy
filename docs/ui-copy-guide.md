# Trust-Preserving UI Copy Guide

> If a sentence cannot truthfully end with "as far as the system can tell"...  
> it is too confident and must be rewritten.

---

## 1. Scan State (Awareness)

These appear at the top of the app. They define the user's mental model.

### Fresh

```
Scan is up to date
Last scanned just now.
```

- "Up to date" is temporal, not absolute
- No claim of correctness
- No green "all good" implication

### Possibly Stale

```
Scan may be out of date
Changes might have occurred since the last scan.
```

- "May" and "might" signal uncertainty
- No urgency
- No instruction yet

### Stale

```
Scan recommended
Files may have changed since the last scan.
```

- Suggestion, not command
- Explains why, not what to do
- Avoids "outdated" (which implies error)

### Action Button (only when stale)

```
Review changes by scanning
```

Never say "Fix" or "Update".

---

## 2. Plan Preview (Intent)

This is the most important copy in the entire system.

### Section Header

```
Proposed changes
Nothing will happen until you approve.
```

This sentence alone eliminates 80% of user anxiety.

### Single Planned Action

```
invoice.pdf → Archive/2024
Because it matched the rule "Archive PDFs older than 30 days".
```

- File name first (anchors reality)
- Arrow implies intent, not action
- "Because" always present

### Multiple Actions Summary

```
14 files would be moved
Each change is shown below with its reason.
```

Never summarize without offering explanation.

### Ambiguous / Skipped File

```
report_final.pdf
Skipped because its location could not be determined safely.
```

Never say "Error" here.  
Skipping is a decision, not a failure.

### Confidence Hint (optional, subtle)

```
This plan is based on the most recent scan.
```

- Avoid "confidence score"
- Avoid percentages
- Avoid colors implying certainty

### Primary Action Button

```
Approve and apply changes
```

**Not:**

- Run
- Execute
- Clean
- Organize

"Apply" implies respect for prior review.

---

## 3. Execution Results (Reality)

This is where honesty matters more than optimism.

### Section Header

```
What happened
```

Not "Results". Not "Success".

### Successful Action

```
invoice.pdf
Moved to Archive/2024.
```

Simple. No celebration.

### Skipped Action

```
summary.pdf
Skipped because the file no longer existed.
```

- "Skipped because…" always present
- Blame is on reality, not the system

### Failed Action

```
taxes.xlsx
Could not be moved because permission was denied.
```

**Never:**

- Show error codes
- Say "unexpected"
- Apologize excessively

### Partial Completion Summary

```
Some changes could not be completed
Details are shown below.
```

Avoid "errors occurred" as a headline.

---

## 4. Undo (Reassurance Without Promises)

Undo is where overconfidence kills trust.

### Undo Button

```
Undo recent changes
```

Not "Revert everything".

### Undo Confirmation Text

```
Undo will attempt to restore files to their previous locations.
Files that cannot be safely restored will be skipped and explained.
```

This sets expectations before anything happens.

### Undo Success

```
invoice.pdf
Restored to its original location.
```

### Undo Skipped

```
notes.txt
Not restored because the original location is now occupied.
```

No blame. No regret language.

### Undo Failure

```
archive.zip
Could not be restored because the file no longer exists.
```

Never say "Undo failed" globally.

---

## 5. History (Memory, Not Logs)

History should read like a journal.

### History Entry

```
May 20, 2024
14 files were moved because they matched the rule "Archive Old PDFs".
```

**Not:**

- "ActionPlan #4921"
- "Batch executed"

### History Detail View

```
Each change below shows what was planned and what actually happened.
```

This reinforces the plan → reality distinction.

---

## 6. Observation / Event Awareness

These are notifications, not alerts.

### Soft Notification

```
Files may have changed
You might want to review by scanning.
```

**Never:**

- Auto-scan
- "Changes detected!" (too confident)

### Suppressed Repeat Notification (internal)

```
Recent changes were already noted.
```

---

## 7. Error States (Global)

### Permission Loss

```
Access to this folder was removed.
You can continue using the app by selecting another folder.
```

No panic. No red language.

### Internal / Unknown Case

```
This change was made by an older or incompatible version of the app and cannot be safely undone.
```

---

## The Final Rule

If a sentence cannot truthfully end with:

> "as far as the system can tell"

…it is too confident and must be rewritten.
