#!/usr/bin/env bash
#
# Reports fixes that are on main but have no equivalent patch on a release
# branch. Compares patch content, not SHAs, so a cherry-pick counts as present.
#
# Usage: backport-audit.sh [release/vX.Y ...]   (default: every release branch)
# Writes Markdown to stdout. A line starting with "  - " is a gap. Always exits 0.
# Needs: full clone, GH_TOKEN, GITHUB_REPOSITORY.

set -euo pipefail

: "${GITHUB_REPOSITORY:?must be set}"
: "${GH_TOKEN:?must be set}"

repo_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"

if [ "$#" -gt 0 ]; then
  refs=("$@")
else
  mapfile -t refs < <(
    git for-each-ref --format='%(refname:strip=3)' 'refs/remotes/origin/release/*'
  )
fi

for ref in "${refs[@]}"; do
  echo "## $ref"

  # Squashing on main and squashing the backport produce different patches for
  # the same change, so git cherry alone reports every backport as missing.
  # These two lists are the evidence that it actually landed.
  picked=$(git log "origin/$ref" --format='%B' \
             | grep -oiE 'cherry picked from commit [0-9a-f]{7,40}' \
             | awk '{print tolower($NF)}' | sort -u || true)

  # A conflicted pick is committed without -x, so it leaves no trailer above.
  # --limit 1000: a truncated list is indistinguishable from a missing backport.
  picked_prs=$(gh pr list --state merged --base "$ref" --limit 1000 \
                 --json headRefName --jq '.[].headRefName' </dev/null \
               | sed -n "s#^backport/${ref}/##p" | sort -u || true)

  open_prs=$(gh pr list --state open --base "$ref" --limit 1000 \
               --json number,headRefName \
               --jq '.[] | "\(.headRefName) \(.number)"' </dev/null \
             | sed -n "s#^backport/${ref}/##p" | sort -u || true)

  missing=$(git cherry "origin/$ref" origin/main | grep '^+' | cut -d' ' -f2 || true)

  if [ -z "$missing" ]; then
    echo "  (nothing missing)"
    echo
    continue
  fi

  count=0
  while read -r sha; do
    [ -z "$sha" ] && continue

    subject=$(git log -1 --format='%s' "$sha")

    if [ -n "$picked" ] \
       && printf '%s\n' "$picked" | grep -qi "^${sha:0:12}"; then
      continue
    fi

    # One request, read twice. </dev/null stops gh eating the loop's stdin.
    pr_json=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/pulls" </dev/null 2>/dev/null || echo '[]')
    pr=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty')
    labels=$(printf '%s' "$pr_json" | jq -r '.[].labels[].name')

    if [ -n "$pr" ] && [ -n "$picked_prs" ] \
       && printf '%s\n' "$picked_prs" | grep -qx "$pr"; then
      continue
    fi
    if printf '%s\n' "$labels" | grep -qx 'no-backport'; then
      continue
    fi

    # Honour the decision the PR recorded: a fix labelled for 4.7 only is not
    # missing from 4.6. Safe because backport-label-check.yml makes a label
    # mandatory, so an unlabelled commit still gets reported.
    targets=$(printf '%s\n' "$labels" | grep '^backport/' || true)
    if [ -n "$targets" ] \
       && ! printf '%s\n' "$targets" | grep -qx "backport/${ref#release/}"; then
      continue
    fi
    if git log -1 --format='%B' "$sha" | grep -qi 'no-backport'; then
      continue
    fi

    # Features are expected to be missing, unless a label says otherwise.
    case "$subject" in
      fix*|Fix*|hotfix*|"revert"*) ;;
      *) [ -n "$targets" ] || continue ;;
    esac

    # Reset per iteration, or the note leaks onto the next commit.
    note=""
    if [ -n "$pr" ] && [ -n "$open_prs" ]; then
      bp=$(printf '%s\n' "$open_prs" | awk -v p="$pr" '$1 == p {print $2}')
      [ -n "$bp" ] && note="  <- backport PR [#$bp]($repo_url/pull/$bp) open, not merged"
    fi

    echo "  - [\`${sha:0:8}\`]($repo_url/commit/$sha) $subject$note"
    count=$((count + 1))
  done <<< "$missing"

  [ "$count" -eq 0 ] && echo "  (nothing missing)"
  echo
done
