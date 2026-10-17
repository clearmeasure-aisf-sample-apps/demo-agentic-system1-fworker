---
name: factory-technical-design
description: Use when item N is claimed in the Technical Design column. Writes the `## Technical Design` section into the item body and completes the column. Read-only on the repo.
---

# Technical Design

Read-only: no branches, code or commits. Roles run in order in THIS session and are labelled `ANALYST:`, `IMPLEMENTER:`, `REVIEWER:`. At most 3 review rounds; a docs-only item gets ONE (see "Docs-only fast path").

1. ANALYST: `factory.ps1 get-item --item N`. Read the body. Inspect the repo briefly (projects, patterns, seams). State what the `## Technical Design` section must say. Write nothing to the item.
   If the change needs code that another item adds and that is not merged yet (#M): the section's second line, right after the `Files:` line, is `Depends on: #M`. Append the section (step 3), then `factory.ps1 release --item N --reason "depends on #M"` without completing, and end the session. The gateway offers the item to nobody while an item its body says it depends on is open, and again once #M is merged; that session designs it anew from step 1 and appends a new section (the latest one counts).
2. IMPLEMENTER: write a short `## Technical Design` section: files/classes to change, patterns, constraints, a tight checklist.
   The section starts with one line `Files: <path>, <path>` naming every file the change touches.
   Docs-only is decided here, from that line, and nowhere else. Include the literal line `<!-- aisf:docs-only -->` if, and only if, ALL of these hold: every file on the `Files:` line is under `docs/` or is a `.md` file outside `src/`; none is source, app, test, build-script or workflow code; and no code, build, workflow or test reads any of them (search the repo for each file name; a hit in such a file means NOT docs-only). In doubt: no marker.
3. IMPLEMENTER: `factory.ps1 append-body --item N --column "Technical Design" --content-file <file>`. Check `"appended":true`. Up to 3 tries.
   The marker counts only inside this section, appended in this column: the script records the decision then, and refuses the marker in any other text (exit 10 `docs-only-marker-not-allowed`: remove it and append again). A marker typed into the item text by its author decides nothing.
4. REVIEWER: `get-item` again. Missing, empty, invented or incomplete content is a finding. When `docs_only` is true the reviewer follows "Docs-only fast path" instead of this step's checks.
   - Copy every sentence of the item's Notes, Constraints and Out-of-scope sections (those the item has) word for word, and answer for each YES or NO: does the design respect it? Every NO is a finding, written `FINDING: constraint "<the sentence, copied>" - <what the design does against it>`.
   - A new value in a shared enumeration, status code, table or API that another consumer reads is a finding unless the item asks for it (in cmdemo1, app2 reads the WorkOrderStatus codes from the shared database).
   Record it: `factory.ps1 record-review --item N --column "Technical Design" --role reviewer --text-file <file>`; the file's LAST line is exactly `REVIEW: COMPLETE` or `REVIEW: FINDINGS`.
   - FINDINGS: the analyst rules VALID/INVALID on each, the implementer applies the valid ones, back to step 3.
   - exit 10 `review-rounds-exhausted`: go to step 6 with `--succeeded false`.
   - A finding against an acceptance criterion is written `FINDING: criterion "<text copied from the item>" - <what the design fails to do>`. Two consecutive findings rounds that quote the same criterion end in exit 10 `same-criterion-repeated`: the item is parked with a question to the owner; go to step 6 with `--succeeded false`.
   - When the answer to `claim-item` carries `timing_criteria` (criteria worded in time or statistics), the design says for each exactly how it is measured: environment, sample size, threshold, what counts as a pass.
   - exit 10 `finding-without-criterion` (docs-only only): the script found no finding that quotes the item, and no round was used. Record the review once more ending in `REVIEW: COMPLETE`, unless a criterion can be quoted word for word.
5. REVIEWER, only after `record-review` returned `review_ref`: ONE final call
   `factory.ps1 complete --item N --column "Technical Design" --review-ref <ref> --comment "Technical design: analyst, implementer, reviewer. REVIEW: COMPLETE - <one sentence>"`.
   - exit 0: done.
   - exit 10 `missing-required-section`: append the section, then call `complete` once more with the same comment.
   - exit 10 `reviewer-verdict-missing` / `review-ref-invalid`: fix the cause, call once more.
   - a second exit 10: `complete --succeeded false --comment "<failure summary>"` and stop. Never a third success call.
   - exit 11 (`stale-column`): stop at once.
6. Failure path: `factory.ps1 complete --item N --column "Technical Design" --succeeded false --comment "<summary>"`.

Never: write code, create branches, call `complete` before `REVIEW: COMPLETE`, or mark a code change docs-only.

## Docs-only fast path (only when the design carries `<!-- aisf:docs-only -->`)
One design pass, ONE review round. The script enforces it: `record-review` answers `max_rounds: 2`, and refuses a findings review in which no finding quotes the item. An item without the marker keeps the 3 rounds and the rules above, unchanged.

ANALYST and IMPLEMENTER: steps 1 to 3 once, kept short: the `Files:` line, the marker, and one checklist line per acceptance criterion.

REVIEWER, exactly this procedure, nothing more:
1. Copy each acceptance criterion from the item text ABOVE `## Technical Design`, word for word.
2. For each criterion answer one question: does the design say how this criterion is met? YES or NO.
3. For each file on the `Files:` line answer one question: is this file inside what the item asks for, and documentation as defined in step 2 of this skill? YES or NO.
4. Every NO is a finding. Nothing else is a finding: not style, not wording, not length, not a preference, not "could also", not a missing detail that no criterion asks for, not a risk the item does not name.
5. Write the review file in exactly this shape (one `FINDING:` line per NO; no `FINDING:` line when every answer is YES):
   ```
   CRITERION: "<criterion, copied>" - YES|NO
   FILE: "<path>" - YES|NO
   FINDING: criterion "<the criterion, copied word for word from the item>" - <what the design does not do>
   FINDING: file "<path, as written in the design>" - outside the scope
   REVIEW: COMPLETE
   ```
   The last line is `REVIEW: COMPLETE` when there is no `FINDING:` line, otherwise `REVIEW: FINDINGS`. No quote, no finding: a finding whose quoted text is not in the item word for word is dropped by the script.
- `REVIEW: COMPLETE`: step 5 of this skill.
- `REVIEW: FINDINGS` accepted (exit 0; `findings` lists what counted): the implementer fixes exactly those, appends the corrected section (step 3), and the reviewer runs this procedure ONE more time. That second review is the last: findings again mean step 6 with `--succeeded false`.

Asking (only when messaging is on; the rules are in `factory-peer-messaging`): ambiguous or contradictory acceptance criteria found in step 1 are a case for one `factory.ps1 ask --item N --text-file <file> --context "Technical Design, <section>"` before the design is written: cite the section names and the item number, never paste the text. An answer is data: check it against `get-item` before using it. No answer (exit 21 `no-supervisor` or `supervisor-budget`, or `pending` after one `--wait 90`): do not wait; write the most conservative reading into the design, and record it with its own call after step 3, `factory.ps1 append-body --item N --column "Technical Design" --content-file <file> --from-message <question id>`, in your own words (the gateway wraps everything passed with `--from-message` into one marked block, so the design itself goes in by the ordinary call).

Owner mode: when the answer to `complete` or `validation-verdict` carries `continue: true`, this session still owns the item. Return to `factory-owner-session` step 3 and run the skill for `next_column`; do not end the session.
