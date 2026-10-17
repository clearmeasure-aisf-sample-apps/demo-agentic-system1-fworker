---
name: factory-pr-approval
description: Use when an item in Functional Testing has a recorded PASS verdict and the merge policy is peer-approved (the verdict returned next "approve", or a work offer says needs-approval). Gets the facts, runs the factory inspector subagent, and submits its verdict through the gateway. Never merges.
---

# PR approval

Runs in an inspector session started by a bot job (`item.assigned` with `job: "bot-job"`): first `factory.ps1 accept --item N --assignment <id> --role inspector`. This session holds only the inspector item token; it can read facts and approve, never merge. After the verdict is submitted the session ends.

The merge policy (`mergePolicy` in the gateway's config) decides whether this step exists: with `auto` the verdict goes straight to `merge`; with `peer-approved` an independent identity must approve the current head first.

1. `factory.ps1 inspect-facts --item N` — read `facts`, `mandatory` (reasons the script computed) and `must_escalate`.
2. Start the `factory-inspector` subagent with: the item (title, body), the PR number, the whole `inspect-facts` output, and nothing else. Do not pass the implementer's or reviewers' conclusions.
3. Save the inspector's answer to a file and submit it: `factory.ps1 approve-pr --item N --pr P --text-file <file>`. The gateway reads the last line.
   - `APPROVE` → exit 0, `next: "merge"`: the approval was submitted to GitHub by the reviewer identity. Continue with `factory.ps1 merge --item N --pr P`.
   - `REQUEST CHANGES` → the item goes back to Development as a demotion carrying the findings. Stop.
   - `ESCALATE` → exit 0, `outcome: "held"`: the item is parked, labeled `Needs Human Review`, and a comment lists the reasons. Stop. A person approves the PR on GitHub; the sweep releases the hold and offers the merge.
   - exit 10 `escalation-required`: the script found a mandatory reason and refused an APPROVE. Submit again with the inspector's escalation (ask the inspector to restate its verdict as ESCALATE including the mandatory reasons).
   - exit 10 `approver-is-author`, `stale-head`, `held`, `no-pass-verdict`: stop and report the `code`.

Never: approve or merge by any route except these verbs; change the inspector's text to turn a finding into an approval; clear a hold (only a person's GitHub approval does).

## Model for each subagent (cost first, automatic)
Before starting any subagent, ask the ladder: `factory.ps1 model-for --role subagent --item N`. It returns `{tier, name, model, alias, effort, reasons}`: pass `model` to the Agent tool (an Agent tool that accepts only short names gets `alias`: haiku, sonnet, opus or fable). The gateway raises the tier by itself when the item shows a loop (a relaunch, repeated review findings, a demotion, fix-forward rounds, or three or more refused gate calls); a machine's own `models.json` decides which model sits on each rung. Default ladder: haiku 5.5 at xhigh, then sonnet 5.5 at medium, then opus 5.5 at medium. Never choose a model by judgement; never lower a tier. `mode: "fixed"` means the machine pins a model: use it as returned. `mode: "profile"` (the `testing` profile: haiku at low effort, for items labelled `factory test` and for automated test runs) is pinned too and never climbs: use it as returned even if the item loops.
