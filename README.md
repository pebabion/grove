<img src="icon.png" width="96" align="right" alt="">

# Grove

[![CI](https://github.com/pebabion/grove/actions/workflows/ci.yml/badge.svg)](https://github.com/pebabion/grove/actions/workflows/ci.yml)

A macOS app for multi-repo git worktree workspaces.

One task usually spans more than one repository. Grove makes a **workspace** — a
folder holding a worktree from each repo you need, all on the same branch — sets
each one up, and tears the whole thing down afterwards.

## Install

Download the DMG from [Releases](https://github.com/pebabion/grove/releases/latest)
and drag Grove to Applications. After that it updates itself: a pill appears when
a newer release exists, and one click installs it and restarts.

Builds are ad-hoc signed rather than notarised, so Gatekeeper blocks the *first*
launch. Right-click Grove and choose Open, or:

```bash
xattr -dr com.apple.quarantine /Applications/Grove.app
```

Grove runs `git`, `gh` and each repo's own setup scripts, and reads repositories
anywhere on disk. No App Sandbox can describe that, so it will never come from
the App Store.

## How it works

**Repo library.** Register each repository once: where the clone is, what branch
to fork from, and how to prepare a fresh worktree. Setup is a shell command, or a
`.grove/setup.sh` committed in the repo — symlink `.env` files, install
dependencies, start a container, whatever that repo needs. Teardown undoes
anything setup did outside the worktree.

**Workspaces.** Tick the repos a piece of work needs; add or remove them later.
Each gets a worktree on a shared branch. Renaming moves the folder and repairs
every worktree inside it.

**Teardown.** Grove lists what a workspace is about to lose — commits on no
remote, ignored-but-real files like `.env.local` — before removing anything.
Everything listed really does disappear, so the list stays worth reading.

Each repo also shows its pull request, and disk usage is measured in the
background, because that is what tells you a workspace is finished with.

The filesystem is the source of truth. `git worktree list` and each workspace's
`grove.json` describe what exists; Grove's own store holds only the library and
caches. Where they disagree, disk wins.

## Hook contract

Setup and teardown hooks run with the new worktree as the working directory:

| Variable | Meaning |
| --- | --- |
| `GROVE_WORKTREE` | the new worktree |
| `GROVE_REPO_ROOT` | the source clone — symlink `.env` from here |
| `GROVE_REPO_NAME` | this repo's name in the library |
| `GROVE_WORKSPACE` | the workspace root |
| `GROVE_WORKSPACE_NAME` | the workspace's directory name |
| `GROVE_BRANCH` | the branch just created or checked out |
| `GROVE_BASE_BRANCH` | what it forked from |

A committed `.grove/setup.sh` beats the library's inline command, since it is
versioned with the code it sets up. Write hooks so they survive running twice —
Grove offers a re-run when a lockfile moves.

## Build

Swift 6 and Xcode. No third-party dependencies.

```bash
make test     # GroveCore
make run      # build Grove.app and launch it
make xcode    # generate the project and open Xcode
make icon     # redraw the app icon
```

`GroveCore` holds all the logic and builds without Xcode. `Grove/` is views and
app plumbing only. `Grove.xcodeproj` is generated from `project.yml` — edit the
spec, never the project file.

Releases go out on a tag:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

## Licence

Icons from [Primer Octicons](https://github.com/primer/octicons); see
[THIRD-PARTY.md](THIRD-PARTY.md).
