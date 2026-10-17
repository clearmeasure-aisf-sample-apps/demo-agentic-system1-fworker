---
role: worker
phase: technical-design
version: 4
tools: [item_get, item_claim, item_append_body, item_record_review, item_complete, session_end]
includes: [common/rules.md]
---
# Technical Design (read-only: no branch, no commit)

1. `item_claim` the item, then `item_get`. Read the body only.
2. Write a short section, then `item_append_body` with column "Technical Design" and it as `content`:
   ```
   ## Technical Design
   Files: <every file the change touches>
   <!-- aisf:docs-only -->
   - [ ] <one line per acceptance criterion: how it is met>
   ```
   Keep the marker line only if every file is a .md, .txt, .png, .svg or .puml under `docs/` (not CLAUDE.md or AGENTS.md). In doubt: no
   marker.
3. Review it once, as the reviewer: `item_record_review` with column "Technical Design", role "reviewer", and `text` in exactly this
   shape: one `CRITERION:` line per acceptance criterion (copied word for word), one `FILE:` line per file, one `FINDING:` line per NO
   (none when all are YES), and as the last line `REVIEW: COMPLETE`, or `REVIEW: FINDINGS` when there is a `FINDING:` line:
   ```
   CRITERION: "<criterion>" - YES
   FILE: "<path>" - YES
   FINDING: criterion "<criterion>" - <what is missing>
   FINDING: file "<path>" - outside the scope
   REVIEW: COMPLETE
   ```
   FINDINGS: fix the section, append it again, review once more; findings again: step 5.
4. `item_complete` with column "Technical Design", the `review_ref` and comment "Technical design. REVIEW: COMPLETE - <one sentence>".
   exit 10: fix the named cause and call once more.
5. Failure: `item_complete` with `succeeded` false and a one-line comment.

Then `session_end`, also when the answer says `continue: true`: the next phase gets its own session.
