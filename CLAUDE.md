# Grove

macOS app for multi-repo worktree workspaces. Swift 6, SwiftUI, no third-party
dependencies.

## Build and test

```bash
swift build                  # GroveCore
swift test                   # run before every commit
xcodegen generate            # regenerate Grove.xcodeproj after editing project.yml
xcodebuild -scheme Grove -configuration Debug build
swift format --in-place --recursive Sources Tests Grove
```

`Grove.xcodeproj` is generated and gitignored. Edit `project.yml`, never the
project file.

## Structure

All logic belongs in `GroveCore`, which builds and tests without Xcode. The
`Grove` target is views and app plumbing only. If a piece of logic is hard to
test because it lives in a view, move it.

## Rules that came from experience

- **Never capture subprocess output through two pipes read in sequence.** A pipe
  blocks the writer at 64KB, so draining stdout then stderr deadlocks on a
  chatty command — which `yarn install` is. `Shell` captures through temporary
  files for this reason. Do not "simplify" it back to pipes.
- **The filesystem is the source of truth.** `git worktree list` plus each
  workspace's `grove.json` describe what exists. Grove's store holds the repo
  library and caches. Anything Grove believes that disk contradicts is wrong,
  because people run `git worktree remove` by hand.
- **Never assume `PATH`.** A GUI app launched from Finder gets roughly
  `/usr/bin:/bin`. Resolve every tool through `ToolPaths`.
- **Base branch is per repo.** Repos disagree about `master` and `main`. Probe
  `origin/HEAD`; never hardcode.
- **A created worktree with a failed setup is a normal state**, not an error to
  throw away. Keep the log, show the repo as `failed`, offer a retry.
- **Serialize git per repo, parallelize setup across repos.** `git worktree add`
  takes a lock on the source clone.

## Destructive operations

Anything that removes a worktree goes through a `WorktreeRisk` audit first, and
the result gets shown to the user. `git status` alone is not enough — it misses
unpushed commits and ignored-but-real files such as `.env.local`.

**Do not add stashes to the audit.** `refs/stash` belongs to the clone and is
shared by every worktree of it, so a stash outlives any worktree it was made in.
Listing them showed a red nine-item warning about work that was never at risk.
`Git.clonewideStashes` exists and is named to say so.

Over-warning is a failure of its own. An alarm that fires on safe things teaches
people to click through the one that matters, so every entry in the audit must be
something that is genuinely gone afterwards.

## Tests

Use swift-testing (`import Testing`, `@Test`, `#expect`). Git operations are
tested against real repositories in temporary directories via the `Sandbox`
helper, not against stubs — these are the operations that destroy work when
wrong.

## Prose

Follow the writing rules in the user's global CLAUDE.md for all docs, commit
messages and PR text.
