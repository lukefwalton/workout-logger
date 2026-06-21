# Making this repository public

Checklist before flipping visibility on GitHub.

## Already handled in-repo

- [x] **Copyright:** [LICENSE](../LICENSE) — Luke F. Walton, all rights reserved (not MIT/open source).
- [x] **Secrets gitignored:** `project.local.yml`, signing assets, `build/`,
  `*.xcodeproj/`, local export plists — see [.gitignore](../.gitignore).
- [x] **Example config only:** [project.local.yml.example](../project.local.yml.example) uses placeholder team ID.
- [x] **Privacy policy:** [docs/privacy.md](privacy.md) matches App Store Connect.
- [x] **Attributions:** [NOTICE.md](../NOTICE.md) for third-party references.

## Before you click "Public" on GitHub

1. **Confirm no secrets in history**
   ```bash
   git log --all -- project.local.yml   # should be empty
   git grep -i 'D7B4B2Q2RW' $(git rev-list --all)  # should find nothing
   ```

2. **Optional:** Add repo topics on GitHub — `ios`, `swift`, `swiftui`, `privacy`,
   `workout-tracker`, `local-first`.

3. **Optional:** Set GitHub **About** link to
   https://lukefwalton.com/private-workout-logger/

4. **Keep Issues enabled** — users can file bugs here or email luke@lukefwalton.com.

5. **Website:** Add a "View source" link on the product page pointing to this repo.

## After going public

- Do not commit `project.local.yml` or signing assets (`.p12`, `.mobileprovision`).
- App Store releases stay tied to your signing identity and Apple Developer account.
