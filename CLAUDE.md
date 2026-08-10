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

### Two silent failures between `add` and a visible banner

Both of these accept the notification and show nothing, with no error to read.

**The app must be signed as a bundle.** A bundle carrying only the linker's ad-hoc
signature on its executable is refused permission: `requestAuthorization` fails with
`UNErrorDomain error 1`. `make app` therefore signs after building, since
`CODE_SIGNING_ALLOWED=NO` leaves it in exactly that state. Check with `codesign -dvv`
— the identifier must be `com.pebabion.Grove`, not `Grove`, and `--verify --strict`
must pass. Location matters too: a bundle under `/private/tmp` is refused whatever
its signature.

**The delegate must implement `willPresent`.** macOS drops notifications from the
frontmost app unless the delegate returns presentation options. `add` succeeds and
nothing is drawn. This is not an edge case for Grove: watching one workspace while a
session in another finishes leaves Grove frontmost, which is the case the feature
exists for.

## Letting Claude Code report for itself

A progress report says work stopped; it cannot say whether the agent finished or
paused to ask something. Claude Code's hooks can, so Grove registers two of them:
`Notification` for "wants a human" and `Stop` for "turn ended". Both were confirmed
firing against a live session before any of this was built, and the payload carried
`cwd` — which is how an event finds its session — plus Claude Code's own wording,
which beats anything Grove would write.

**Do not depend on a documented field being present.** The docs list a `type` on
`Notification` events; the live capture had none. Parsing treats every field except
`hook_event_name` and `cwd` as optional and drops what it cannot read.

**Never write the payload into the watched directory.** The relay writes to a temp
file and moves it in. Creating the file in place and then filling it is a race the
watcher wins: it wakes on the empty file, reads nothing, deletes it, and the write
lands on a deleted inode. Every event was silently lost that way.

**`settings.json` belongs to the user and to other tools.** A real one held five hook
events registered by something else. Grove appends, never replaces, keeps a copy
before its first edit, and refuses to rewrite a file it cannot parse.

Hook events and progress reports describe the same moment, so notifying from both
would mean two notifications. Once a directory has delivered a hook event, its
progress reports only drive the sidebar. Notifications are also keyed by session
identifier, so a later signal replaces an earlier one instead of stacking.

## Rescan means ask again

`rescan()` forces a pull request refresh. It used to refresh nothing, so a merged
pull request kept showing as open until the next launch, and even then a fifteen
minute cache could hold the stale answer. An explicit action must not serve a cache.

## Selecting text in the terminal

Mouse reporting is off by default, and that is what makes selection work.

SwiftTerm discards the selection whenever mouse reporting is *permitted* — not when a
program is actually using it. Both `linefeed` and `feedPrepare` clear it on that flag
alone, so with reporting on, a selection survives until the next chunk of output:
milliseconds in a live session. `feedPrepare` is internal, so overriding `linefeed`
alone fixes nothing; the flag is the only lever.

Nothing is lost by default. Claude Code sets no mouse tracking mode at all — measured
through a PTY, it sets only focus reporting, bracketed paste and synchronised output —
and neither does a shell. The setting exists for programs that do read the mouse, such
as vim or lazygit.

## Scrollback

Sessions ask for 10,000 lines. SwiftTerm's default is 500, which a long agent
conversation passes in minutes, and the top of the transcript was simply gone.

**It has to be set through `Terminal.changeScrollback` before the process starts.**
The buffer's capacity is fixed when the terminal is created, and the view creates its
own terminal with `TerminalOptions(cols:rows:)` — there is no init that takes options
and no way to get in first. Measured against the real library: assigning
`options.scrollback` afterwards changes nothing and still keeps 525 lines,
`changeScrollback` keeps everything, and neither a resize nor `setup(isReset:)` undoes
it. It cannot recover lines already discarded, which is why it runs before the shell
starts.

## Skills a workspace's repos carry

An agent started at the workspace root cannot see them. Claude Code loads project
skills from the starting directory and its parents; a repo's `.claude/skills` is a
level down. Skills below the starting directory do load, but only after Claude reads a
file in that subdirectory, so until then they are missing from autocomplete and cannot
be invoked by name.

Grove symlinks each one into the workspace root, which Claude Code supports directly.
Verified against real sessions rather than inferred: a probe skill invisible from the
workspace root became available through a link, and **the name it answered to was the
link's name**, not the `name:` in its own frontmatter. That is what makes collisions
solvable.

- **Both forms.** Commands were merged into skills, and repos in use have both, so
  `.claude/commands/*.md` is linked as well. Also verified with a real session.
- **Names stay put unless they clash.** One repo with a `deploy` skill keeps `/deploy`.
  Two repos with `deploy` both get prefixed, and neither keeps the bare name — choosing
  a winner would be arbitrary and would change with the order repos were added.
- **Targets are relative.** Renaming a workspace moves the folder, and an absolute
  target would point at where it used to be.
- **Only Grove's own links are removed.** Recognised by shape — relative, and pointing
  at `../../<repo>/<.claude/kind>/<entry>` — not by being unfamiliar. These directories
  belong to Claude Code, and people keep their own skills in them.

Rebuilt on create, on adding or removing a repo, and on rescan, since a branch can add
or drop a skill without Grove doing anything.

## Crashes, and the two shapes they took

Both were found by reading `~/Library/Logs/DiagnosticReports/Grove-*.ips` rather than
by guessing. Parse one with `json.loads` on the first line for the header and on the
rest for the body; the faulting thread's frames carry symbols.

**A callback written inside main-actor code is checked for the main executor as it is
entered.** A closure written in a `@MainActor` method is main-actor isolated, so Swift
asserts the executor when the closure is called. LaunchServices calls
`NSWorkspace.open`'s completion on its own queue, and the app trapped in
`dispatch_assert_queue_fail` — while opening an editor. Hopping inside the closure
does not save it: the check runs first. Use the awaiting form of the API, or write
`{ @Sendable ... }` so the closure carries no isolation and hop explicitly. Every
callback Grove hands out is now one or the other.

**Positions are not identities.** `RepoEditor` held an index and read
`library.repos[index]`; deleting a repo left it subscripting past the end.
`redetectBase` resolved an index, awaited the network, then wrote through it. Both go
through `RepoLibrary.update(_:_:)`, which finds the repo by name at the moment of the
change and does nothing if it is gone. Never carry an index across an await or across
a view update.

## Measuring coverage

```bash
swift test --enable-code-coverage
BIN=.build/arm64-apple-macosx/debug/GroveCorePackageTests.xctest/Contents/MacOS/GroveCorePackageTests
PROF=.build/arm64-apple-macosx/debug/codecov/default.profdata
xcrun llvm-cov report "$BIN" -instr-profile="$PROF" -ignore-filename-regex='(Tests|\.build)'
```

Only `GroveCore` is measured, which is the point of keeping logic there. Chase the
files where a gap costs something — `WorkspaceService` moves worktrees, `Shell` runs
every git call — rather than the percentage.

**A test holding a `Sandbox` in `_` deletes the repositories it just made.** The
sandbox removes its directory when released, so a fixture that returns one while the
caller discards it fails with "No such file or directory" from git. Bind it by name
for the length of the test.

## Redraw corruption on resize

Claude Code repaints in place: measured through a PTY across a live resize, it sends
42 erase-lines and two cursor moves, no full clear, and it never uses the alternate
screen. So what is on screen afterwards depends entirely on the terminal reflowing the
old content exactly where the program assumes it is.

SwiftTerm 1.16.0 fixes both halves of that — "stale rows when repainting in place while
scrolled back", and erase-line no longer changing soft-wrap boundaries. Keep the
dependency current when a redraw bug shows up; this one was released the same day it
was reported.

The buffer itself was never the problem. Feeding wrapped lines and resizing shows every
logical line intact at both 500 and 10,000 lines of scrollback, so a garbled screen is
a rendering or cursor-position fault, not lost content.

## Claude Code will not report progress to Grove

Measured, by starting it under different values and counting `OSC 9;4`:

| `TERM_PROGRAM` | progress reports |
| --- | --- |
| unset, `Grove`, `iTerm.app`, `WezTerm` | none |
| `ghostty` | yes |

So the progress signal Grove's notifications were built on never arrives, and the log
shows it: many sessions started, not one `osc 9 payload` line. Claude Code rings no
bell either. **For Claude Code, the hook relay is not an improvement, it is the only
route**, which is why one switch turns on notifications and installs the relay
together — a separate switch for it was a question nobody wanted to answer. The progress path still earns its place for other tools, and for Claude Code
if it ever recognises more terminals.

Do not fix this by claiming to be ghostty. Terminal detection gates more than
progress: a program told it is talking to ghostty may use the kitty keyboard protocol
and other things Grove does not implement, and Shift + Return already had to be
hand-fitted here.

## Quote the hook command

Claude Code runs a hook command through `/bin/sh -c`, and Grove's relay lives under
"Application Support", which has a space in it. Registered bare, every hook failed with

    /bin/sh: /Users/you/Library/Application: No such file or directory

and the failure showed up in the user's session, not in Grove. `ClaudeHooks.command`
quotes the path; nothing should register it any other way.

`isInstalled` compares the whole command rather than looking for the script path
somewhere inside it, so an entry left by a version that did not quote reads as *not*
installed and gets rewritten on the next launch. Recognising Grove's entry loosely is
still right for removal — that has to find the broken ones too.

## Viewing files

Read-only, deliberately. Agents rewrite these files while they are on screen, so
anything that could save would need to know what changed underneath it, and Grove
already opens a real editor in one click.

Highlighting is highlight.js through JavaScriptCore (Highlightr), not tree-sitter.
Tree-sitter is what an editor wants because it reparses as you type; nothing here is
typed into. The grammar bundle that would make tree-sitter practical, CodeEditLanguages,
is a 1.4GB repository with no declared licence and no commits since June 2025.

Two things were measured and both changed the design:

- **Searching cost 91ms a keystroke** over 25,000 paths — what three real repos hold.
  Lowercasing and splitting into `Character`s per keystroke was most of it, and sorting
  every match was the rest. `FileIndex` folds each path to lowercase UTF-8 bytes once and
  keeps a running best `limit` instead of sorting the lot: 3.5ms.
- **Highlighting costs about a millisecond per kilobyte** — 42ms for a middling source
  file, near a second at the 1MB limit. It runs in an actor off the main one, once per
  selection. Calling it from a view body means repeating it for every unrelated change.
