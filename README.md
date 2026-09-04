# Branching sandbox

Trunk + maintenance branches. See BRANCHING.md.

- `main` - trunk, always releasable, holds the next minor
- `feature/*` - short-lived, squash-merged into main
- `release/X.Y` - one per supported minor, until EOL

Fixes land on `main` first and are cherry-picked down. Never merge up.
