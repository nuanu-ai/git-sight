#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / ".build" / "VisualFixtures"
BASE_DATE = datetime(2026, 9, 1, 12, 0, tzinfo=timezone.utc)
CASES = [
    "linear",
    "merge",
    "parallel",
    "interleaved",
    "three-branches",
    "active-merge",
    "nested-merges",
    "long-content",
    "history-limit",
]


def git(repo, *args, env=None):
    subprocess.run(
        ["/usr/bin/git", "-C", str(repo), *args],
        check=True,
        env=env,
        stdout=subprocess.DEVNULL,
    )


def dated_environment(number=None, date=None):
    value = date or (BASE_DATE + timedelta(hours=number)).isoformat()
    env = os.environ.copy()
    env.update({"GIT_AUTHOR_DATE": value, "GIT_COMMITTER_DATE": value})
    return env


def commit(repo, subject, number=None, date=None):
    path = repo / f"file-{number if number is not None else 0}.txt"
    path.write_text(f"{subject}\n", encoding="utf-8")
    git(repo, "add", path.name)
    git(repo, "commit", "-m", subject, env=dated_environment(number, date))


def merge(repo, branch, subject, number):
    git(
        repo,
        "merge",
        "--no-ff",
        branch,
        "-m",
        subject,
        env=dated_environment(number),
    )


def repository(case):
    repo = FIXTURES / case / case
    repo.mkdir(parents=True)
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.name", "Visual Test")
    git(repo, "config", "user.email", "visual@example.com")
    return repo


def linear():
    repo = repository("linear")
    for number in range(12):
        commit(repo, f"Linear change {number + 1}", number)


def merge_case():
    repo = repository("merge")
    commit(repo, "Initial shared root", 0)
    git(repo, "branch", "feature/parser")
    commit(repo, "Main advances without disturbing the feature rail", 1)
    git(repo, "checkout", "feature/parser")
    commit(repo, "Add the first parser increment", 2)
    commit(repo, "Finish parser error recovery", 3)
    git(repo, "checkout", "main")
    merge(repo, "feature/parser", "Merge feature/parser", 4)
    commit(repo, "Main continues after the merge", 5)


def parallel():
    repo = repository("parallel")
    commit(repo, "Initial shared root", 0)
    git(repo, "branch", "feature/one")
    git(repo, "branch", "feature/two")
    commit(repo, "Main advance", 1)
    git(repo, "checkout", "feature/one")
    commit(repo, "Feature one base", 2)
    commit(repo, "Feature one tip", 3)
    git(repo, "checkout", "feature/two")
    commit(repo, "Feature two base", 4)
    commit(repo, "Feature two tip", 5)
    git(repo, "checkout", "main")
    merge(repo, "feature/one", "Merge feature one", 6)
    merge(repo, "feature/two", "Merge feature two", 7)
    commit(repo, "Main after both merges", 8)


def interleaved():
    repo = repository("interleaved")
    commit(repo, "Initial shared root", 0)
    git(repo, "branch", "side")
    commit(repo, "Main advance", 1)
    git(repo, "checkout", "side")
    commit(repo, "Side work", 2)
    git(repo, "checkout", "main")
    merge(repo, "side", "Merge side", 3)


def three_branches():
    repo = repository("three-branches")
    commit(repo, "Shared root", 0)
    for branch in ["alpha", "beta", "gamma"]:
        git(repo, "branch", branch)
    commit(repo, "Main remains active", 1)
    for number, branch in enumerate(["alpha", "beta", "gamma"]):
        git(repo, "checkout", branch)
        commit(repo, f"{branch} base", 2 + number * 2)
        commit(repo, f"{branch} tip", 3 + number * 2)
    git(repo, "checkout", "main")
    commit(repo, "Main newest tip", 8)


def active_merge():
    repo = repository("active-merge")
    commit(repo, "Shared root", 0)
    git(repo, "branch", "feature")
    git(repo, "branch", "independent")
    commit(repo, "Main advance", 1)
    git(repo, "checkout", "feature")
    commit(repo, "Feature work", 2)
    git(repo, "checkout", "independent")
    commit(repo, "Independent base", 3)
    commit(repo, "Independent tip", 4)
    git(repo, "checkout", "main")
    merge(repo, "feature", "Merge while independent branch stays active", 5)
    commit(repo, "Main after merge", 6)


def nested_merges():
    repo = repository("nested-merges")
    commit(repo, "Shared root", 0)
    git(repo, "branch", "left")
    git(repo, "branch", "right")
    commit(repo, "Main base", 1)
    git(repo, "checkout", "left")
    commit(repo, "Left base", 2)
    git(repo, "checkout", "right")
    commit(repo, "Right base", 3)
    git(repo, "checkout", "left")
    merge(repo, "right", "Left absorbs right", 4)
    git(repo, "checkout", "main")
    merge(repo, "left", "Main absorbs nested merge", 5)
    git(repo, "checkout", "right")
    commit(repo, "Right continues independently", 6)
    git(repo, "checkout", "main")
    merge(repo, "right", "Main absorbs right continuation", 7)
    commit(repo, "Main final tip", 8)


def long_content():
    repo = repository("long-content")
    commit(repo, "Initial root with a deliberately long but realistic commit message that must remain readable at the standard window width", 0)
    git(repo, "branch", "feature/very-long-branch-name-for-layout-verification")
    for number in range(1, 10):
        commit(repo, f"{number}: Preserve complete product history while reconciling independently written records and avoiding duplicate visible entries", number)
    git(repo, "checkout", "feature/very-long-branch-name-for-layout-verification")
    commit(repo, "A concurrent branch commit with detailed implementation context and a long visible subject", 10)


def history_limit():
    repo = repository("history-limit")
    commit(repo, "Branch root outside the recent-history window", date="2027-01-01T00:00:00+00:00")
    git(repo, "branch", "side")
    for number in range(1, 102):
        commit(repo, f"Main {number}", number)
        if number == 1:
            git(repo, "branch", "old")


if __name__ == "__main__":
    if FIXTURES.exists():
        shutil.rmtree(FIXTURES)
    linear()
    merge_case()
    parallel()
    interleaved()
    three_branches()
    active_merge()
    nested_merges()
    long_content()
    history_limit()
    for case in CASES:
        repo = FIXTURES / case / case
        graph = subprocess.run(
            ["/usr/bin/git", "-C", str(repo), "log", "--graph", "--all", "--topo-order", "--oneline"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        (FIXTURES / case / "git-graph.txt").write_text(graph, encoding="utf-8")
    print(FIXTURES)
