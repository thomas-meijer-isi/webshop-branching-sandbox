# Exercises

Run these in order against the sandbox. Each one has an expected outcome — if you
get something different, that's the interesting part.

---

## 1. A clean fix, backported to both branches

The happy path.

```
git switch main && git pull
git switch -c fix/checkout-total
echo "checkout-fix" >> src/app.txt
git commit -am "fix: checkout total rounds incorrectly"
git push -u origin fix/checkout-total
gh pr create --base main --title "fix: checkout total rounds incorrectly" --fill
```

Now merge it *without* a label.

**Expect:** the `Backport decision` check fails and blocks the merge.

Add the labels and watch it pass:

```
gh pr edit --add-label "backport/v4.7" --add-label "backport/v4.6"
gh pr merge --squash
```

**Expect:** two backport PRs open within a minute, one per branch. Merge both.

Check the trailer survived:

```
git fetch && git log origin/release/v4.6 -1 --format=%B
```

**Expect:** a `(cherry picked from commit …)` line. That trailer is what makes the
audit reliable when a pick had to be adapted.

---

## 2. A feature — proving `no-backport`

```
git switch main
git switch -c feature/wishlist
echo "wishlist" >> src/app.txt
git commit -am "feat: wishlist"
git push -u origin feature/wishlist
gh pr create --base main --title "feat: wishlist" --fill
gh pr edit --add-label "no-backport"
gh pr merge --squash
```

**Expect:** check passes, no backport PRs created.

Then try to add both `no-backport` and `backport/v4.7` to a PR.

**Expect:** the check fails — the two are mutually exclusive. A decision that says
both "this goes nowhere" and "this goes to 4.7" is not a decision.

---

## 3. A conflicting cherry-pick — the important one

Make `release/v4.6` diverge first:

```
git switch release/v4.6 && git pull
git switch -c fix/prep-divergence
sed -i '1s/.*/RESTRUCTURED/' src/app.txt
git commit -am "refactor: restructure config header"
git push -u origin fix/prep-divergence
gh pr create --base release/v4.6 --title "refactor: restructure config header" --fill
gh pr merge --squash
```

Now fix the same line on `main`:

```
git switch main && git pull
git switch -c fix/config-header
sed -i '1s/.*/version: 4.8.0-dev-patched/' src/app.txt
git commit -am "fix: config header parsing"
git push -u origin fix/config-header
gh pr create --base main --title "fix: config header parsing" --fill
gh pr edit --add-label "backport/v4.6"
gh pr merge --squash
```

**Expect:** the backport PR opens *anyway*, with conflict markers in the diff and a
comment explaining how to finish it by hand. It does not silently skip.

This is the behaviour that matters. A tool that skipped on conflict would leave a
supported version quietly unfixed.

Resolve it in the GitHub web editor to see how bad that experience is — it informs
whether you want people doing this in the browser or locally.

---

## 4. A fix that only applies to the old branch

The documented exception: the code no longer exists on `main`.

```
git switch release/v4.6 && git pull
git switch -c fix/legacy-only
echo "legacy-fix" >> src/app.txt
git commit -am "fix: legacy import path (not present on main)"
git push -u origin fix/legacy-only
gh pr create --base release/v4.6 --title "fix: legacy import path" --fill
```

**Expect:** no label check — it only runs on PRs into `main`. Merge it directly.

Note what you *didn't* have to do, and note that nothing recorded why this bypassed
`main`. That gap is worth discussing: a PR template for release-branch PRs asking
"why doesn't this apply to main?" would close it.

---

## 5. Try to break the rules

Each of these should be refused. If any succeeds, a ruleset is wrong.

```
# a hotfix branch
git switch -c hotfix/4.6.4 release/v4.6 && git push -u origin hotfix/4.6.4
```
**Expect:** rejected by the branch-naming ruleset.

```
# merging a release branch up into main
git switch main && git merge release/v4.6 && git push
```
**Expect:** rejected — direct pushes to `main` need a PR. (The *rule* against
merging up is social; the ruleset only stops the direct push. Worth knowing which
guardrails are enforced and which are convention.)

```
# moving a tag
git tag -f v4.6.0 && git push -f origin v4.6.0
```
**Expect:** rejected by the immutable-tags ruleset.

```
# deleting a release branch
git push origin --delete release/v4.6
```
**Expect:** rejected. At real EOL you'd disable the ruleset briefly, delete, then
re-enable.

---

## 6. The release gate

Create a fix labelled `backport/v4.7`, merge it, but **do not** merge the resulting
backport PR. Then try to release:

```
gh workflow run release.yml --ref release/v4.7 -f version=4.7.1
```

**Expect:** the gate job fails and names the open PR. You cannot tag a version that
is knowingly missing a fix.

Merge the backport, run it again.

**Expect:** tag `v4.7.1` created, GitHub Release published.

Also try tagging `4.7.1` from `release/v4.6`.

**Expect:** refused — the version has to match the branch.

---

## 7. Let the audit catch you

Merge a fix into `main` with `backport/v4.6`, then **close** the backport PR without
merging. This simulates the realistic failure: someone decided it was too awkward
and moved on.

Run the audit by hand rather than waiting for the schedule:

```
gh workflow run backport-audit.yml
```

**Expect:** an issue opens listing the commit as missing from `release/v4.6`.

This is the gate that catches what the other three leak. Note also its limitation:
it finds *missing* backports, not *wrong* ones. A cherry-pick that applied cleanly
but is semantically wrong on the old branch looks identical to a correct one.

---

## 8. Optional — measure the thing you actually care about

Add ten commits to `main`, backport five, and time how long the audit takes plus
how long resolving one conflict takes. Multiply by your real fix volume.

That number — not the elegance of the model — is what tells you whether two
maintenance branches are affordable with the team you have.

---

## Appendix — diagnosing a rejected push

Two different things reject a push, and the error messages do not reliably tell
them apart. The backport action in particular reports *any* push failure as
"token lacks permission", which is often wrong.

**Ask GitHub what rules apply to that exact ref:**

```
gh api "repos/:owner/<repo>/rules/branches/<url-encoded-ref>"
```

Slashes are `%2F`, so `backport/release/v4.6/4` becomes
`backport%2Frelease%2Fv4.6%2F4`. A `creation` entry in the output means a ruleset
blocked it. Empty output means the ruleset is fine and the problem is
permissions.

**If it is permissions:** Settings > Actions > General > Workflow permissions >
Read and write, plus the checkbox allowing Actions to create pull requests.
A workflow's own `permissions:` block can only narrow the repo default, never
raise it.

**If it is a ruleset:** dump what is actually stored, not what the UI renders.

```
gh api "repos/:owner/<repo>/rulesets/<id>" \
  --jq '{enforcement, include: .conditions.ref_name.include,
         exclude: .conditions.ref_name.exclude, rules: [.rules[].type]}'
```

### The fnmatch trap

GitHub matches refs with `fnmatch(FNM_PATHNAME)`. A trailing bare `**` does
**not** cross `/`. So:

| pattern | `backport/12` | `backport/release/v4.6/12` |
|---|---|---|
| `backport/*` | matches | no |
| `backport/**` | matches | **no** |
| `backport/**/*` | no | matches |

`**/` is the recursive form; a trailing `**` degrades to `*`. Exclude both
`prefix/*` and `prefix/**/*` for every prefix, or deep branch names slip through
and get blocked.

After changing patterns, verify both directions — that the allowed name passes
*and* that a disallowed one is still refused:

```
gh api "repos/:owner/<repo>/rules/branches/backport%2Frelease%2Fv4.6%2F4"  # empty
gh api "repos/:owner/<repo>/rules/branches/hotfix%2F4.6.4"               # creation
```

The second check matters most. It is easy to fix a false negative by excluding
everything, at which point the rule silently stops doing anything.