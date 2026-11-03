#!/usr/bin/env python3
"""Builds a folder of made-up repositories that covers every verdict git-sight shows.

Used for screenshots and for checking the window by eye without pointing it at real work.
Dates are relative to now, so the ages in the window stay the same whenever it is rebuilt.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build" / "DemoWorkspace"
# Hidden folders are skipped by the scan, so the fake servers do not show up as repositories.
REMOTES = WORKSPACE / ".remotes"
NOW = datetime.now(timezone.utc)
# Marks a folder this script built, so a rebuild never deletes anything else.
MARKER = ".git-sight-demo"
# The user's own git config could sign commits with their key or run their hooks.
ISOLATED = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


def git(repo, *args, days_ago=0):
    date = (NOW - timedelta(days=days_ago)).isoformat()
    env = os.environ | ISOLATED | {"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
    subprocess.run(["git", "-C", str(repo), *args], check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write(repo, name, text, days_ago=0):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    stamp = (NOW - timedelta(days=days_ago)).timestamp()
    os.utime(path, (stamp, stamp))


def commit(repo, name, subject, days_ago):
    write(repo, name, f"{subject}\n")
    git(repo, "add", name)
    git(repo, "commit", "-m", subject, days_ago=days_ago)


def repository(name, remote=True, history=4, days_ago=90):
    repo = WORKSPACE / name
    repo.mkdir(parents=True)
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.name", "Alex Morgan")
    git(repo, "config", "user.email", "alex@example.com")
    for number in range(history):
        commit(repo, f"src/module{number}.txt", f"Add module {number + 1}", days_ago - number)
    if remote:
        origin = REMOTES / f"{name}.git"
        subprocess.run(["git", "init", "--bare", "-b", "main", str(origin)], check=True, env=os.environ | ISOLATED, stdout=subprocess.DEVNULL)
        git(repo, "remote", "add", "origin", str(origin))
        git(repo, "push", "-u", "origin", "main")
    return repo


def billing_service():
    # Forgotten: a feature branch with a merge inside, never pushed, two months old.
    repo = repository("billing-service", days_ago=120)
    git(repo, "checkout", "-b", "feature/invoice-export")
    commit(repo, "export/csv.txt", "Export invoices as CSV", 70)
    git(repo, "checkout", "-b", "feature/pdf-layout")
    commit(repo, "export/pdf.txt", "Draft PDF layout for invoices", 68)
    commit(repo, "export/pdf-fonts.txt", "Embed fonts in PDF export", 67)
    git(repo, "checkout", "feature/invoice-export")
    commit(repo, "export/columns.txt", "Let users pick export columns", 66)
    git(repo, "merge", "--no-ff", "feature/pdf-layout", "-m", "Merge PDF layout into invoice export", days_ago=65)
    commit(repo, "export/tests.txt", "Cover export of empty invoices", 64)
    git(repo, "checkout", "main")
    git(repo, "branch", "-D", "feature/pdf-layout")


def mobile_app():
    # Abandoned: a stash from last week and edits nobody touched for five days.
    repo = repository("mobile-app", days_ago=60)
    write(repo, "src/module0.txt", "Try a shorter onboarding\n")
    git(repo, "stash", "push", "-m", "try a shorter onboarding", days_ago=9)
    write(repo, "src/module1.txt", "Rename settings screens\n", days_ago=5)
    write(repo, "src/settings/Profile.txt", "Profile screen\n", days_ago=5)


def docs_site():
    # In progress: fresh edits and a branch the server already merged and deleted.
    repo = repository("docs-site", days_ago=30)
    git(repo, "checkout", "-b", "fix/broken-links")
    commit(repo, "guide/links.txt", "Fix broken links in the guide", 20)
    git(repo, "push", "-u", "origin", "fix/broken-links")
    git(repo, "checkout", "main")
    subprocess.run(["git", "--git-dir", str(REMOTES / "docs-site.git"), "branch", "-D", "fix/broken-links"], check=True, env=os.environ | ISOLATED, stdout=subprocess.DEVNULL)
    git(repo, "fetch", "--prune")
    write(repo, "guide/install.txt", "Install on macOS 14\n")


def data_pipeline():
    # Forgotten: an agent's worktree on a detached HEAD with commits no branch holds.
    repo = repository("data-pipeline", days_ago=100)
    worktree = WORKSPACE / "agents" / "data-pipeline-retry"
    worktree.parent.mkdir(parents=True, exist_ok=True)
    git(repo, "worktree", "add", "--detach", str(worktree))
    commit(worktree, "jobs/retry.txt", "Retry failed imports with backoff", 45)
    commit(worktree, "jobs/retry-tests.txt", "Test retry limits", 44)


def search_api():
    # Abandoned on the server: a pushed branch main never got, and a merged one an agent's worktree still holds.
    repo = repository("search-api", days_ago=80)
    git(repo, "checkout", "-b", "feature/fuzzy-search")
    commit(repo, "search/fuzzy.txt", "Match queries with typos", 26)
    commit(repo, "search/fuzzy-rank.txt", "Rank fuzzy matches below exact ones", 25)
    git(repo, "push", "-u", "origin", "feature/fuzzy-search")
    git(repo, "checkout", "-b", "fix/timeouts", "main")
    commit(repo, "search/timeouts.txt", "Cap query time at two seconds", 40)
    git(repo, "push", "-u", "origin", "fix/timeouts")
    git(repo, "checkout", "main")
    git(repo, "merge", "--ff-only", "fix/timeouts")
    git(repo, "push", "origin", "main")
    worktree = WORKSPACE / "agents" / "search-api-timeouts"
    worktree.parent.mkdir(parents=True, exist_ok=True)
    git(repo, "worktree", "add", str(worktree), "fix/timeouts")


def experiments():
    # No remote: every commit lives only here.
    repo = repository("experiments", remote=False, days_ago=40)
    write(repo, "notes/ideas.txt", "Ideas for the next prototype\n", days_ago=2)


def clean(name):
    repository(name, history=3, days_ago=50)


if __name__ == "__main__":
    if WORKSPACE.exists():
        if any(WORKSPACE.iterdir()) and not (WORKSPACE / MARKER).exists():
            sys.exit(f"{WORKSPACE} exists and was not built by this script; pick an empty or new folder")
        shutil.rmtree(WORKSPACE)
    WORKSPACE.mkdir(parents=True)
    (WORKSPACE / MARKER).touch()
    billing_service()
    mobile_app()
    docs_site()
    data_pipeline()
    search_api()
    experiments()
    for name in ["website", "design-tokens", "infra-config"]:
        clean(name)
    print(WORKSPACE)
