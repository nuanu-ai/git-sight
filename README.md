# git-sight

A native macOS app that finds work you left behind in your git repositories: branches you never pushed, stashes you forgot, uncommitted edits, commits stranded in a worktree an agent created and abandoned.

It never changes a repository. When something needs fixing, copy a ready-made task for your coding agent and let it do the work.

## What counts as left behind

git-sight looks for work that exists only on this machine:

- uncommitted files in any worktree, dated by the newest file change;
- local branches with commits that no remote-tracking branch contains;
- commits on a detached HEAD that no branch, tag or remote holds;
- stashes.

Each piece gets a verdict by how long it has gone untouched:

| Verdict | Meaning |
| --- | --- |
| Забыто | untouched for over 30 days |
| Заброшено | untouched for over 3 days (a stash: over 1 day) |
| В работе | fresh work, or a repository with no remote at all |
| Чисто | everything is on the server |

A branch whose upstream was deleted on the server stays "В работе" however old it is. That is what a squash merge leaves behind, and git cannot tell it apart from lost work. A repository is as bad as its worst piece of work.

## Using it

Pick the folder that holds your repositories. git-sight remembers it and scans every repository inside, skipping hidden folders, `Library` and `node_modules`. After that it follows the repositories as they change: an FSEvents stream watches their folders and worktrees, and an edit, commit or stash shows up within a second, without rescanning everything. A full rescan still runs when you come back to the app and every five minutes while it is open.

The window has three columns: repositories, the findings of the selected repository, and the detail of one finding. Repositories changed in the last 15 minutes sit at the top under "Сейчас" with what just happened, so you can watch several agents work at once. The rest are grouped by verdict. A branch shows the commits that are not on the server, down to the commit the server already has; click a commit to see its files. Uncommitted work and stashes show their files.

"Скопировать задачу для агента" puts a self-contained request on the clipboard: what was found, where, and what to do about it. It always ends by telling the agent not to delete anything without asking you.

The interface is in Russian for now.

## Read-only by design

Every git call runs with `--no-optional-locks`, hooks pointed at `/dev/null`, fsmonitor off, and `GIT_*` variables removed from the environment, so reading a repository does not take its locks or run its hooks. An integration test plants an fsmonitor hook and checks that a scan never fires it.

## Build and run

Requires macOS 14 or later and a Swift toolchain. Command Line Tools are enough.

```sh
sh Scripts/package_app.sh
open Artifacts/GitSight.app
```

`swift run GitSight` also works, but a bare executable often opens its window behind the terminal.

## Development

Run the integration tests:

```sh
swift run GitSightTests
```

`swift test` needs Xcode, so the tests are a plain executable.

To look at the window without pointing it at real work, build a folder of made-up repositories that covers every verdict and render the window to a PNG:

```sh
python3 Scripts/make_demo_workspace.py
sh Scripts/render_window.sh window.png .build/DemoWorkspace billing-service branch 1360 860 light
```

The sidebar and toolbar are drawn with live glass, which an offscreen capture cannot see, so they come out blank in the PNG.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the test-first workflow, mutation checks and review policy.

## License

MIT
