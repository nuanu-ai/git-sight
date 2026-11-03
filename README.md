<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="">
</p>

<h1 align="center">git-sight</h1>

<p align="center">
  See the work your agents left behind, in every repository at once.<br>
  A native macOS app. Read-only by design.
</p>

Run a few coding agents for a week and your disk fills with branches nobody pushed, stashes nobody remembers, worktrees an agent created and walked away from. git does not tell you any of this unless you go into each repository and ask.

git-sight asks for you. Point it at the folder with your repositories and it shows, on one screen, whether there is unfinished work, where it is, and how long it has been sitting there.

## What it finds

| | |
| --- | --- |
| **Uncommitted files** | in any worktree, dated by the newest change |
| **Unpushed commits** | on local branches, against every remote, not just the upstream |
| **Orphaned commits** | on a detached HEAD that no branch, tag or remote holds |
| **Stashes** | pinned by hash, so stashing again does not shuffle them |
| **Unmerged branches** | pushed, but never made it into the default branch; squash merges count as merged |
| **Leftovers** | merged branches and the agent worktrees still holding them |

Work that exists only on this machine gets a verdict by age: **В работе** for the first three days, **Заброшено** after that (a stash after one day), **Забыто** after a month. A pushed branch that never got merged ages slower: two weeks in progress, abandoned after that, forgotten after two months. Leftovers lose nothing, so they are only ever clutter. A repository is as bad as its worst piece, and its row says how much is lying around: «сейчас на main · 21 ветка, 13 не влиты · 4 ворктри».

## A Source Control panel for every repository

- **Live.** An FSEvents watcher rereads only the repository that changed. Edits, commits and stashes show up within a second, and repositories touched in the last 15 minutes rise to the top under «Сейчас».
- **The graph.** All branches, remote branches, tags and agent worktrees, drawn the way VS Code draws it. Commits the server lacks sit on an orange band. Scroll and it keeps reading history.
- **Files and diffs.** Click a commit and its files open under it. Click a file and its diff opens below the graph.
- **A task for your agent.** For anything found, one button copies a self-contained request: what was found, where, what to do. It always ends with "do not delete anything without asking me".
- **Readable.** ⌘+ and ⌘− scale all text, the graph included.

## Read-only, and it means it

Every git call runs with `--no-optional-locks`, hooks pointed at `/dev/null`, fsmonitor and signature checks off, and `GIT_*` variables stripped from the environment. Filter drivers from a repository's own config are switched off; diffs go through plumbing with `--no-ext-diff --no-textconv`, so the index is never rewritten. Squash merges are found by comparing files, not by test-merging, which would write objects. A repository's config cannot make git-sight run a program. Integration tests plant hooks, fsmonitor daemons, signing programs, filters and diff drivers, and check that none of them fire and the index stays as it was.

## Build

macOS 14 or later. Command Line Tools are enough.

```sh
sh Scripts/package_app.sh
open Artifacts/GitSight.app
```

## Develop

```sh
swift run GitSightTests                 # integration tests against real git repositories
python3 Scripts/make_demo_workspace.py  # a folder of made-up repositories, one per verdict
sh Scripts/render_window.sh window.png .build/DemoWorkspace search-api unmerged 1360 860 light
```

`swift test` needs Xcode, so the tests are a plain executable. Every test lands red first, then green with the mutants it killed named in the commit. See [CONTRIBUTING.md](CONTRIBUTING.md).

The interface is in Russian.

## Releasing

The app updates itself with [Sparkle](https://sparkle-project.org). Every hour it reads `appcast.xml` from `main`, and when a new version is out, an update button appears in the window.

Once, before the first release, make a signing key. After `swift build` the Sparkle tools are in `.build/artifacts/sparkle/Sparkle/bin`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It keeps the private key in your login keychain and prints the public key. Paste that into `SUPublicEDKey` in `Resources/Info.plist` over the placeholder. Export a backup with `generate_keys -x private-key-file`: lose the key and installed copies will refuse every later update.

For each release:

```sh
sh Scripts/release.sh 1.3
```

The script sets the version, builds and signs `Artifacts/GitSight-1.3.zip`, adds it to `appcast.xml`, and prints the commands that publish it. It publishes nothing itself. Upload the zip before pushing `main`, so the appcast never points at a file that isn't there yet.

The app is signed ad hoc, without a Developer ID, so after the first download macOS asks before opening it. Updates through Sparkle don't ask again.

## License

MIT
