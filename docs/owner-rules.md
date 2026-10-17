# Owner rules

Rules of the owner that every decision of the factory's oversight sessions follows. The backlog keeper reads this file before it decides
(`plugin/skills/factory-backlog-keeper/SKILL.md`); no session edits it. Only the owner changes it, in a pull request he merges (this path is
in `.github/CODEOWNERS`). A rule here wins over a default policy of a skill.

1. **Keep database compatibility with app2.** The second application that reads the work-orders database (app2) must keep working with every
   release. A schema change is additive: add a table or a nullable column, never drop, rename or change the type of one in the same release.
   A change that needs a removal is split into expand (add the new form, write both), migrate the readers, and contract (remove the old form)
   in a later item that depends on the first.
2. **No criterion about security or data loss is relaxed by a session.** Such a criterion stays as written until the owner changes it.
3. **A criterion worded with "must" is the owner's.** A session may clarify around it in the design, never amend it.
