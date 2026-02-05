Great question — and good timing.

### Quick answer first (so it doesn’t linger)

You **already have all the prompts you need for building**.
For UX, the _next_ “prompt-style” artifact is this checklist. It replaces prompts because UX should be **evaluated**, not generated.

So: you don’t _wait_ for another prompt — you **apply this checklist to every string you write**.
If later you want a _Cursor prompt for enforcing the checklist automatically_, we can do that too.

Now, here’s the checklist.

---

# UI Copy Checklist

_(Contract-Preserving, Trust-Centered)_

Use this checklist **for every user-facing sentence** before it ships.

If a line fails **any** check, it must be rewritten.

---

## 1️⃣ Epistemic Honesty (Truthfulness)

**Does the copy accurately reflect what the system knows?**

- ⬜ Uses uncertainty where uncertainty exists (`may`, `might`, `could`)
- ⬜ Avoids implying omniscience
- ⬜ Does NOT claim correctness, completeness, or finality
- ⬜ Could safely end with: _“as far as the system can tell”_

❌ Red flags:

- “Detected all changes”
- “Everything is up to date”
- “Fixed”, “Resolved”, “Guaranteed”

---

## 2️⃣ Intent vs Action Separation

**Does the copy clearly distinguish planning from execution?**

- ⬜ Uses _conditional_ language for plans (`would`, `proposed`, `if approved`)
- ⬜ Uses _past tense_ for executed actions
- ⬜ Never implies execution happened without approval
- ⬜ Preview text never sounds like a result

❌ Red flags:

- “Files will be moved” (in preview)
- “Cleaning complete” (ever)

---

## 3️⃣ Explanation Completeness

**Can the user answer “why?” immediately after reading this?**

- ⬜ Includes “because …” or equivalent reasoning
- ⬜ Reason refers to rules, time, or observable facts
- ⬜ Reason is human-readable, not technical
- ⬜ No action or skip is unexplained

❌ Red flags:

- “Skipped”
- “Failed”
- “Error occurred”

(with no reason attached)

---

## 4️⃣ Blame Direction (Critical)

**Does the copy avoid blaming the user or the system unfairly?**

- ⬜ Attributes failure to conditions, not mistakes
- ⬜ Uses neutral phrasing (“could not”, “was unavailable”)
- ⬜ Avoids “you did”, “the app failed”, “unexpected”

❌ Red flags:

- “You don’t have permission”
- “The app encountered an error”
- “Unexpected failure”

---

## 5️⃣ Reversibility Signaling

**Does the copy respect undo semantics?**

- ⬜ Never promises undo success
- ⬜ Explains when undo may skip
- ⬜ Avoids “revert everything” language
- ⬜ Makes reversibility feel cautious, not magical

❌ Red flags:

- “Undo all changes”
- “Restore everything”

---

## 6️⃣ Anxiety Management

**Does the copy lower stress instead of raising urgency?**

- ⬜ No countdowns, alarms, or pressure language
- ⬜ Suggestions are optional, not commands
- ⬜ No repeated nagging phrasing
- ⬜ Calm, measured tone

❌ Red flags:

- “Action required”
- “Immediate attention needed”
- “Fix now”

---

## 7️⃣ Consistency with System Contract

**Does this copy violate any invariant?**

- ⬜ Does not imply auto-execution
- ⬜ Does not imply observer authority
- ⬜ Does not imply permanent deletion
- ⬜ Does not imply hidden background work

❌ Red flags:

- “Automatically organized”
- “Changes applied in background”
- “Deleted permanently”

---

## 8️⃣ Temporal Accuracy

**Is the time reference honest and precise?**

- ⬜ Uses relative time (“just now”, “earlier today”)
- ⬜ Avoids absolute claims about the present
- ⬜ Does not imply continuous monitoring guarantees

❌ Red flags:

- “Currently accurate”
- “Always up to date”

---

## 9️⃣ Minimalism (Less Is Safer)

**Is this the minimum wording needed to be honest?**

- ⬜ No decorative language
- ⬜ No celebration language
- ⬜ No emotional manipulation
- ⬜ One idea per sentence

❌ Red flags:

- Confetti copy
- Emojis
- Marketing adjectives

---

## 10️⃣ Final Kill Test (Mandatory)

Read the copy aloud and ask:

> **“If this turns out to be wrong, would I feel misled?”**

- ⬜ If **no** → acceptable
- ⬜ If **yes** → rewrite

This test overrides all others.

---

# How to Use This Checklist (Practically)

- Apply it:
  - when writing new copy
  - during code review
  - before releases

- Treat failed items as **bugs**, not style issues
- Never waive a check “just this once”

---

## About “the prompt” (closing the loop)

You don’t get _another_ prompt automatically because:

- **Engineering steps** benefit from prompts
- **UX correctness** benefits from checklists and review
