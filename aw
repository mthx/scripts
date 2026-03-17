#!/usr/bin/env python3
"""aw - Watch GitHub Actions for the current branch and notify on completion.

Usage:
  aw              Watch runs for HEAD commit on current branch
  aw --all        Watch all active runs on current branch (not just HEAD)
  aw --poll N     Set poll interval in seconds (default: 30)

Requires: gh (authenticated), git
Optional: alerter (brew install vjeantet/tap/alerter) for click-to-focus
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import time


def run(cmd, **kwargs):
    r = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def git(*args):
    out = run(["git", *args])
    if out is None:
        print(f"aw: git {args[0]} failed", file=sys.stderr)
        sys.exit(1)
    return out


def gh_run_list(repo, branch, head_sha, head_only):
    cmd = [
        "gh", "run", "list", "-R", repo,
        "--branch", branch,
        "--json", "databaseId,name,status,conclusion,headSha,event,createdAt",
        "--limit", "20",
    ]
    if head_only:
        cmd += ["--commit", head_sha]
    out = run(cmd)
    return json.loads(out) if out else []


def focus_worktree(repo_root, branch):
    """Focus the Ghostty tab for a worktree via wt-focus."""
    run(["zsh", "-ic", f"wt-focus -r {repo_root} {branch}"])


def notify(title, message, sound, repo_root, branch):
    if shutil.which("alerter"):
        result = run([
            "alerter",
            "--title", title,
            "--message", message,
            "--sound", sound,
            "--actions", "Show",
            "--group", f"aw-{title}",
            "--timeout", "30",
            "--json",
        ])
        if result:
            try:
                data = json.loads(result)
                if data.get("activationType") in ("contentsClicked", "actionClicked"):
                    focus_worktree(repo_root, branch)
            except json.JSONDecodeError:
                pass
    else:
        # osascript fallback — no click action
        run([
            "osascript", "-e",
            f'display notification "{message}" with title "{title}" sound name "{sound}"',
        ])


STATUS_ICONS = {
    "success": "✓", "failure": "✗", "cancelled": "⊘", "skipped": "–",
    "queued": "◯", "waiting": "◯", "pending": "◯", "in_progress": "●",
}


def print_status(runs, prev_lines):
    # Overwrite previous output
    if prev_lines > 0:
        sys.stdout.write(f"\033[{prev_lines}A\033[J")

    lines = []
    for r in runs:
        state = r["conclusion"] or r["status"]
        icon = STATUS_ICONS.get(state, "?")
        lines.append(f"  {icon} {r['name']} ({state})")

    print("\n".join(lines))
    sys.stdout.flush()
    return len(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="Watch all runs on branch, not just HEAD commit")
    parser.add_argument("--poll", type=int, default=30, help="Poll interval in seconds (default: 30)")
    args = parser.parse_args()

    head_only = not args.all

    branch = git("branch", "--show-current")
    if not branch:
        print("aw: not on a branch (detached HEAD?)", file=sys.stderr)
        sys.exit(1)

    repo_root = git("rev-parse", "--show-toplevel")
    remote_url = git("remote", "get-url", "origin")

    # Extract owner/repo from SSH or HTTPS URL
    repo = remote_url
    for prefix in ("git@github.com:", "https://github.com/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix):]
            break
    repo = repo.removesuffix(".git")

    if "/" not in repo:
        print(f"aw: could not parse GitHub repo from origin: {remote_url}", file=sys.stderr)
        sys.exit(1)

    head_sha = git("rev-parse", "HEAD")
    short_sha = head_sha[:7]

    # Wait for runs to appear
    runs = []
    for attempt in range(10):
        runs = gh_run_list(repo, branch, head_sha, head_only)
        if runs:
            break
        if attempt == 0:
            print("  waiting for runs...")
        time.sleep(5)

    if not runs:
        print(f"  no workflow runs found", file=sys.stderr)
        sys.exit(1)

    # Poll loop
    prev_lines = 0
    while True:
        runs = gh_run_list(repo, branch, head_sha, head_only)
        prev_lines = print_status(runs, prev_lines)

        active = sum(1 for r in runs if r["status"] != "completed")
        if active == 0:
            break

        time.sleep(args.poll)

    # Fetch bot comment URLs from associated PR
    bot_urls = []
    pr_json = run(["gh", "pr", "list", "-R", repo, "--head", branch, "--json", "number", "--limit", "1"])
    if pr_json:
        prs = json.loads(pr_json)
        if prs:
            pr_number = prs[0]["number"]
            comments_json = run([
                "gh", "api", f"repos/{repo}/issues/{pr_number}/comments",
                "--jq", '.[] | select(.user.login == "github-actions[bot]") | .body',
            ])
            if comments_json:
                bot_urls = re.findall(r'https?://\S+', comments_json)

    # Final summary — replace the live status block
    prev_lines = print_status(runs, prev_lines)
    sys.stdout.write(f"\033[{prev_lines}A\033[J")

    for r in runs:
        state = r["conclusion"] or r["status"]
        icon = STATUS_ICONS.get(state, "?")
        print(f"{r['name']} {icon}")
        if r["conclusion"] == "failure":
            print(f"  https://github.com/{repo}/actions/runs/{r['databaseId']}")
            print(f"  gh run view {r['databaseId']} -R {repo} --log-failed")

    if bot_urls:
        print()
        for url in bot_urls:
            print(url)

    # Notify
    failed = sum(1 for r in runs if r["conclusion"] == "failure")
    cancelled = sum(1 for r in runs if r["conclusion"] == "cancelled")
    succeeded = sum(1 for r in runs if r["conclusion"] == "success")
    total = len(runs)

    if failed:
        notify("Build Failed", f"{repo}@{branch}: {failed}/{total} failed", "Basso", repo_root, branch)
        sys.exit(1)
    elif cancelled and not succeeded:
        notify("Build Cancelled", f"{repo}@{branch}: cancelled", "Basso", repo_root, branch)
        sys.exit(1)
    else:
        notify("Build Passed", f"{repo}@{branch}: all green", "default", repo_root, branch)


if __name__ == "__main__":
    main()
