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

**Build with `make app`, not `xcodebuild` directly.** The make target regenerates
the project first. Calling xcodebuild alone leaves the project stale, so a new file
is silently left out of the build and a version bump in `project.yml` never reaches
the bundle — which is how an installed build once reported a version two releases
old.

Do not try to prove what a build contains with `strings` or `nm`. The app is one
Swift module with everything internal, so both report almost nothing: `nm` finds 123
symbols and no UI string is visible. Compare the object file's timestamp against the
source instead — `build/Build/Intermediates.noindex/.../Objects-normal/arm64/`.

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

## Has the work landed?

**Never answer this from `merge-base --is-ancestor` alone.** A squash or rebase
merge rewrites the commit, so a fully merged branch is never an ancestor of its
base — and squash is how most teams merge. A real workspace showed a branch whose
pull request had been merged reporting as unmerged, next to a branch with no pull
request at all reporting as merged.

The pull request's own state is the only reliable signal, and Grove already has
it. A commit count against the base cannot stand in: it reaches zero both for a
branch never committed to and for one whose commits the base has absorbed, so it
says nothing about merging either way.

The teardown badge therefore shows only what the pull request says — merged, or
closed unmerged — and nothing at all otherwise. The ordinary case needs no label;
the card already reports "nothing unsaved, safe to remove" when there is nothing
to lose.

## Knowing when an agent wants you

Grove notifies from the terminal's own byte stream, not from anything Claude Code
specific. Two signals, both measured against a real session rather than assumed:

- **`OSC 9;4;<state>`** — a progress report. Claude Code sends `3` when it starts
  working and `0` when it stops. This is the reliable one, and it needs no setup.
- **The bell** — supported because other tools ring it. Claude Code did not ring one
  in either capture, so nothing depends on it.

**Do not build the "needs input" case on the bell.** A raw count of `0x07` bytes in a
capture is misleading: every OSC sequence ends with BEL, so a session that rang
nothing still shows ten of them. Strip `ESC ] … BEL` before counting.

Finishing and stopping to ask a question arrive identically, because an agent
awaiting permission has stopped working. Grove does not distinguish them — both mean
the session is waiting for you, which is the whole content of the notification.

`SwiftTerm`'s `progressReport(source:report:)` is `public` but not `open`, so it
cannot be overridden. `registerOscHandler(code: 9)` replaces SwiftTerm's own parsing,
so `GroveTerminalView` hands the parsed report back to it afterwards and the built-in
progress bar keeps working.

**Notifications need the app launched as a bundle.** Ad-hoc signing is fine —
`requestAuthorization` is granted for an ad-hoc signed app opened through Finder. Run
the executable inside the bundle directly and the same call fails with "Notifications
are not allowed for this application", which looks like a signing problem and is not.
