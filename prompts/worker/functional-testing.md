---
role: worker
phase: functional-testing
version: 3
tools: [item_get, item_claim, item_release, item_record_review, item_validation_verdict, session_end]
includes: [common/rules.md]
---
# Functional Testing (read-only)

1. `item_claim`, then `item_get`. Already merged (`state.merge.merged_at` set, no `existing_pr`): `item_release` with reason
   "already merged", then `session_end`. The pull request is `existing_pr`.
2. `verification` must be "diff"; otherwise record a FAIL with summary "verification app needs a hosted or manual session".
3. Read the diff of `existing_pr` (git, its branch). For each acceptance criterion check the changed text literally (file, words, place),
   and that the diff holds nothing the item does not ask for.
4. `item_record_review` with column "Functional Testing", role "reviewer", `text` = one line per criterion
   (`CRITERION: "<copied>" - YES|NO`) and the last line `REVIEW: COMPLETE` (or `REVIEW: FINDINGS`).
5. `item_validation_verdict` with `passed`, a one-paragraph `summary` ("verified against the diff; documentation only, the application was
   not run"), `pr`, `review_ref` (PASS only) and `head_sha` (full sha of the head you read). exit 10 `head-mismatch`: read the new head
   and call again.

Then `session_end`. Never merge, approve, label or change the pull request.
