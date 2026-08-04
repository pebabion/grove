# Grove

A macOS app for multi-repo worktree workspaces.

One task usually spans more than one repository. Grove creates a **workspace** —
a folder holding a git worktree from each repo you need, all on the same branch —
sets each one up, and tears the whole thing down when the work is done.

Successor to [`cwt`](https://github.com/pebabion/cwt), rebuilt native and
without its Linear and VS Code coupling.

## Model

**Repo library.** Register each repository once: where the clone lives, what
branch to fork from, and how to set a fresh worktree up. Setup is a shell
command or a `.grove/setup.sh` committed in the repo, so it can do whatever the
repo needs — symlink `.env` files, install dependencies, start a container.
Teardown is its mirror image and undoes anything setup did outside the worktree.

**Workspaces.** Pick the repos a piece of work needs; add or remove them later.
Each becomes a worktree on a shared branch inside the workspace folder.

**Teardown.** Grove shows exactly what a workspace is about to lose — unpushed
commits, ignored-but-real files like `.env.local` — before removing anything.
Everything it lists is something that will be gone afterwards, so the list stays
worth reading.

The filesystem stays the source of truth. `git worktree list` and each
workspace's `grove.json` describe reality; Grove's own store holds the library
and a cache. When they disagree, disk wins.

## Layout

```
Package.swift          GroveCore — all logic, testable without Xcode
Sources/GroveCore/
  Shell.swift          subprocess runner, output captured via temp files
  Git.swift            typed wrapper over the git CLI
  ToolPaths.swift      login-shell PATH discovery
  Models.swift         repo library, workspaces, hook kinds
  Hooks.swift          setup/teardown contract and resolution order
  Storage.swift        atomic JSON persistence
Grove/                 SwiftUI app
project.yml            XcodeGen spec — the .xcodeproj is generated, not committed
```

## Build

```bash
swift build                  # GroveCore
swift test                   # GroveCore tests

xcodegen generate            # produce Grove.xcodeproj from project.yml
xcodebuild -scheme Grove -configuration Debug build
open Grove.xcodeproj          # or work in the IDE
```

## Setup script contract

A setup or teardown hook runs with the new worktree as its working directory and
receives:

| Variable | Meaning |
| --- | --- |
| `GROVE_WORKTREE` | the new worktree |
| `GROVE_REPO_ROOT` | the source clone — symlink `.env` from here |
| `GROVE_REPO_NAME` | this repo's name in the library |
| `GROVE_WORKSPACE` | the workspace root |
| `GROVE_WORKSPACE_NAME` | the workspace's directory name |
| `GROVE_BRANCH` | the branch just created or checked out |
| `GROVE_BASE_BRANCH` | what it forked from |

A committed `.grove/setup.sh` wins over the library's inline command: it is
versioned with the code it sets up. Write hooks so they can run twice — Grove
offers a re-run when a lockfile changes.

## State

Early. `GroveCore` has the git layer, the data model, the hook contract and
persistence, all under test. The app is a shell that proves the bundle builds
and can find its tools. Next: repo library UI, workspace scanning, create and
teardown flows.

## Distribution

Grove spawns `git`, `gh` and arbitrary per-repo setup scripts, and reads
repositories anywhere on disk. No App Sandbox can express that, so this ships as
a notarized DMG rather than through the App Store.
