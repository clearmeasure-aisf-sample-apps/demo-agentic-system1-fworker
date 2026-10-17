---
role: worker
phase: development
version: 4
tools: [item_get, item_claim, item_record_review, item_complete, pr_open, pr_wait_checks, pr_checks, session_end]
includes: [common/rules.md]
---
# Development (docs-only items in this runtime)

1. `item_claim`, then `item_get`. If `docs_only` is false: `item_complete` with `succeeded` false and comment "not docs-only", then
   `session_end`.
2. With git: branch `factory-worker/N-development` from master, change only the files on the design's `Files:` line, commit with `#N`,
   push. No build.
3. `pr_open` with `head` that branch, a `title` and a short `body`. If it answers `build_owed: true`, remove the non-doc file and push.
   `pr_open` exit 10 (`private-build-required`, `pr-not-created`, any other): `item_complete` with `succeeded` false naming the code.
4. `pr_wait_checks`; exit 21 (still running or `rerun-started`): call it at most 2 more times, then go on to step 5. exit 10
   `checks-red`: read `checks.checks[].data.log` (`pr_checks`); when `likelyPreexisting` is true go on to step 5 (the gateway handles it),
   else fix, push and wait again. The same red check twice: `item_complete` with `succeeded` false.
5. Review the diff once: `item_record_review` with column "Development", role "reviewer", `text` = one line per criterion
   (`CRITERION: "<copied>" - YES|NO`) and the last line `REVIEW: COMPLETE` (or `REVIEW: FINDINGS`: fix, push, review again).
6. `item_complete` with column "Development", the `review_ref`, comment "PR open, CI green - <PR link>. REVIEW: COMPLETE". exit 21
   (`accepted-checks-pending`) is success. exit 10: fix the named cause, one more call.

Then `session_end`, also when the answer says `continue: true`.
