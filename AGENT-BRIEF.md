# Agent brief — validating the branching sandbox

You are helping Thomas validate a Git branching and release workflow in a
throwaway GitHub repository before it is adopted on a real product. Read this
whole file before running anything.

---

## 1. Context

**Who:** Thomas leads a five-person .NET development team at ISI Publishing.

**The product this is for:** Webshop — a .NET application installed *per
customer*. Different customers run different versions. Some upgrade slowly
because they have per-customer customization (widgets, custom CSS, custom
JavaScript) that has to be verified by hand on their own staging environment.

**The problem being solved:** development output rose sharply with AI
assistance, and Gitflow stopped coping. Webshop was being maintained across five
long-lived branches at once (`develop` for 4.8, `release` for 4.7, and two
simultaneous hotfix branches for 4.6.2 and 4.6.3). Every bugfix potentially had
to land in up to five places.

**The constraint that shapes everything:** the team has one tester, and testing
is not that person's primary job. Development throughput went up; test
throughput did not. So the bottleneck is now validation, not writing code. This
matters when Thomas asks about cadence — the honest answer is usually "fewer
releases", not "ship faster".

**What this sandbox is for:** proving the *mechanics* work before touching
Webshop. It cannot prove the strategy works; that only shows up in production.

---

## 2. The model being validated

Three kinds of branch. Nothing else is long-lived.

| Branch | Lifetime | Purpose |
|---|---|---|
| `main` | forever | Trunk. Always releasable. Holds the next unreleased minor. |
| `feature/*`, `fix/*` | < 2 days | One PR, squash-merged into `main`. |
| `release/X.Y` | until EOL | One per supported minor. Maintenance only. |
| `backport/*` | minutes | Created by automation. Not created by hand. |

Deliberately absent: `develop`, `hotfix/*`, and any branch named after a patch
version. **Patch versions are tags on a release branch, never branches.**

### The core invariant

> Fixes land on `main` FIRST, then are cherry-picked DOWN to release branches.
> Never merge a release branch up into `main`.

This makes `main` structurally incapable of missing a fix that exists on an older
supported version.

Documented exception: if the affected code no longer exists on `main`, the fix
goes directly to the release branch as its own PR. This should be rare enough to
notice.

### Other rules that matter

- **Backports carry fixes, never features.** A customer-funded feature is never
  backported to an older release. If a customer wants it, they upgrade.
- **Version ordering must hold.** Anything fixed in 4.6.x must be fixed in every
  later version, or a customer upgrading 4.6 → 4.7 sees the bug return.
- **A fix may skip a version only if the bug does not exist there** — not because
  the cherry-pick was awkward. "Too annoying" and "not applicable" must not
  produce the same empty checkbox.

---

## 3. Current repository state

```
main             4.8.0-dev        trunk
release/v4.7     tag v4.7.0       supported
release/v4.6     tag v4.6.0       supported
```

Release branches carry a `v` prefix. Tags are `vX.Y.Z`, so `release/v4.7` holds
`v4.7.0`, `v4.7.1`, and so on.

### Labels

| Label | Meaning |
|---|---|
| `backport/v4.6` | cherry-pick to `release/v4.6` |
| `backport/v4.7` | cherry-pick to `release/v4.7` |
| `no-backport` | deliberately not backported |
| `backport-audit` | applied to issues opened by the audit workflow |

Labels are named after the **version** (`backport/v4.6`), not the branch
(`release/v4.6`). Those differ on purpose, and that difference is the one thing
in this setup that has already gone wrong once, so it is worth stating plainly:

The backport action has **no mapping input**. Its `label_pattern` capture group
is fed straight to `git checkout`. Point it at `backport/v4.6` and it looks for a
branch literally called `v4.6`, which does not exist.

So `backport.yml` does the translation itself, in a step named *Map backport
labels to release branches*: strip `backport/`, prepend `release/`, and verify
the branch exists before using it. `label_pattern` is deliberately set to a regex
matching nothing, so the action contributes no targets of its own — every target
comes from `target_branches`, computed by that step.

Two consequences worth remembering:

- A label whose branch does not exist **fails the workflow** rather than being
  skipped. A silent skip would be indistinguishable from a deliberate decision
  not to backport, which is exactly the ambiguity this model exists to remove.
- `backport-label-check.yml` derives the accepted label names from the release
  branches that exist (`refs/heads/release/v4.6` → `backport/v4.6`). The two
  workflows perform the same mapping in opposite directions. Change one and you
  must change the other.

### Workflows

| File | Trigger | Does |
|---|---|---|
| `backport-label-check.yml` | PR to `main` | Requires one of the labels above. Fails the PR otherwise. |
| `backport.yml` | PR merged, or `/backport` comment | Opens one cherry-pick PR per label. On conflict opens a draft PR with conflicts committed. |
| `backport-audit.yml` | weekday cron + manual | `git cherry` per release branch; opens an issue listing fixes present on `main` but missing downstream. |
| `release.yml` | manual dispatch | Refuses to tag if a backport PR for that branch is still open. Then tags and publishes. |

### Rulesets

| Name | Effect |
|---|---|
| `protected-lines` | `main` + `release/*`: PR required, linear history, no force push, no deletion |
| `main-checks` | `main` only: requires the `Backport decision` status check |
| `branch-naming` | only `feature/`, `fix/`, `release/`, `backport/` branches may be created |
| `immutable-tags` | `v*` tags cannot be deleted, updated, or force-pushed |

`Backport decision` is scoped to `main` alone on purpose. That workflow triggers
on `pull_request` with `branches: [main]`, so it never runs on a PR targeting a
release branch. Requiring it there too made every backport PR permanently
unmergeable, and blocked branch creation under `release/*` outright.

---

## 4. Traps already hit — do not rediscover these

These cost real time. They are fixed in the current scripts, but they will
resurface if anything is regenerated.

### 4.1 fnmatch patterns — the big one

GitHub matches refs with `fnmatch(FNM_PATHNAME)`. **A trailing bare `**` does not
cross `/`.**

| pattern | `backport/12` | `backport/release/v4.6/12` |
|---|---|---|
| `backport/*` | matches | no |
| `backport/**` | matches | **no** |
| `backport/**/*` | no | matches |

So every prefix needs **both** `prefix/*` and `prefix/**/*` in the exclude list.
Getting this wrong blocks the backport action's own pushes.

### 4.2 The misleading error message

When a ruleset blocks the backport action's push, the action reports:

> *"This usually means the token lacks permission... Consider using a Personal
> Access Token"*

**This is often wrong.** Do not reach for a PAT. Diagnose properly:

```
gh api "repos/OWNER/REPO/rules/branches/<url-encoded-ref>"
```

Slashes are `%2F`. A `creation` entry means a ruleset blocked it. Empty output
means it really is permissions.

### 4.3 UI vs API pattern prefixes

The API stores fully-qualified refs (`refs/heads/feature/**/*`). The UI form
takes bare patterns (`feature/**/*`). Mixing them means an exclusion silently
matches nothing. Always dump what is *stored*:

```
gh api "repos/OWNER/REPO/rulesets/<id>" \
  --jq '{enforcement, include: .conditions.ref_name.include,
         exclude: .conditions.ref_name.exclude, rules: [.rules[].type]}'
```

### 4.4 Workflow permissions

A workflow's `permissions:` block can only *narrow* the repository default, never
raise it. If Settings → Actions → General → Workflow permissions is read-only,
`contents: write` in the YAML does nothing. The "allow Actions to create pull
requests" checkbox is a separate setting and is also required.

### 4.5 Rulesets need the right plan

Rulesets work on public repos with GitHub Free, and on private repos only with
Pro/Team/Enterprise. Metadata restrictions (the native "restrict branch names"
rule) appear to be Enterprise Cloud only — hence the inverted
`~ALL` + exclude + `creation` approach used here.

If a ruleset page shows a "won't be enforced" banner, rules are advisory and the
guardrail exercises will pass when they should fail.

### 4.6 Rulesets are not idempotent

`POST /rulesets` creates a new one every time. Re-running bootstrap produces
duplicates with the same name. Check for them before diagnosing odd behaviour.

---

## 5. Your job

Work through `EXERCISES.md` with Thomas. Eight exercises: a clean backport, a
feature with `no-backport`, a deliberate conflict, a release-branch-only fix,
guardrail violations, the release gate, the audit catching a skipped backport,
and a volume measurement.

### How to behave

- **Verify, do not assume.** Much of the pain above came from confident guesses
  about pattern semantics and tool behaviour. When something fails, query the
  API for ground truth before forming a theory.
- **Check both directions after changing a rule.** That the allowed thing passes
  *and* the disallowed thing is still refused. Over-excluding silently disables a
  rule, which looks identical to success.
- **Read the workflow run log**, not just the bot's summary comment. The
  underlying `git` error line distinguishes `GH013: Repository rule violations`
  from `403`.
- **Do not weaken a guardrail to make an exercise pass.** If a rule blocks
  something it should not, fix the rule. If it blocks something it should, that
  is the exercise succeeding.
- **Say when you do not know.** Thomas would rather run a one-command experiment
  than receive a confident wrong answer. He has already caught one.

### Useful commands

```
gh pr checks                                        # what ran on this PR
gh run list --limit 5                               # recent workflow runs
gh run view <id> --log-failed                       # the actual error
gh api "repos/OWNER/REPO/rules/branches/<ref>"      # why was this ref refused
gh api "repos/OWNER/REPO/rulesets"                  # list, check for duplicates
git cherry release/v4.6 main                         # '+' missing, '-' present
gh workflow run backport-audit.yml                  # run the audit now
```

`git cherry` compares by patch-id, so a cherry-picked commit registers as present
despite a different SHA. That is the whole basis of the audit.

---

## 6. Open questions — not yours to decide

These are pending business decisions. If they come up, note them; do not resolve
them.

1. How long does a minor version receive patches? (proposed: 9 months,
   time-based rather than "current + 1", so an off-cycle release cannot shorten a
   slow customer's upgrade runway)
2. Annual validation budget — how many releases can one part-time tester absorb?
   (proposed: ~6, i.e. 4 quarterly + 2 spare)
3. Who owns release sign-off?
4. Do customer-funded features grant exclusivity, or just early access?
5. Is an off-cycle release a quoted line item?
6. Funding automated regression testing — the only item that raises capacity
   rather than rationing it.

---

## 7. Known gaps in the current setup

Worth raising if relevant, but not blockers:

- The audit filters candidate commits by subject prefix (`fix:`), which is crude
  and will miss things. The team does not use Conventional Commits; adopting them
  would fix this, but that is a separate decision.
- A fix written directly against a release branch records no reason for bypassing
  `main`. A PR template for release-branch PRs would close this.
- The audit finds *missing* backports, not *wrong* ones. A cherry-pick that
  applied cleanly but is semantically wrong on the older branch is
  indistinguishable from a correct one. Only human review catches that.
- Backport PRs created with `GITHUB_TOKEN` do not trigger `pull_request` events,
  so other workflows will not run on them. Harmless here (they target
  `release/*`, where the label check does not apply) but worth knowing.