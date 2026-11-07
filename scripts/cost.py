#!/usr/bin/env python3
"""What each ticket cost: agent minutes, runs, failed runs, escalations, Claude spend.

    scripts/cost.py --db <kanban.db> --state <.factory dir> [--repo <target repo>] [--all]

A ticket is a build worktree: the build task (workspace kind 'worktree') plus the
review, security and QA runs in the same worktree (QA and security tasks use it as
a 'dir' workspace). Integration tasks have their own worktree, so they show up as
their own line. Planner runs are summed separately.

By default only delivered tickets are listed: QA done and nothing still open in the
worktree. --all lists open tickets too. "merged" means the build branch is on main
in --repo.

The board DB is opened read-only (PRAGMA query_only). Escalation spend comes from
the JSON that `claude -p --output-format json` writes to .factory/escalations/<task>.log.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time

FAILED = ("crashed", "timed_out", "gave_up", "reclaimed", "rate_limited", "spawn_failed", "stale")
OPEN = ("todo", "ready", "running", "review", "blocked", "triage", "scheduled")


def connect(path):
    conn = sqlite3.connect(path, timeout=5)
    conn.execute("PRAGMA query_only = ON")
    return conn


def escalation(state, task_id):
    """(count, turns, cost_usd, tokens) from .factory/escalations/<task>.{marker,log}."""
    d = os.path.join(state, "escalations")
    if not os.path.exists(os.path.join(d, f"{task_id}.marker")) and not os.path.exists(os.path.join(d, f"{task_id}.log")):
        return 0, 0, 0.0, 0
    turns, cost, tokens = 0, 0.0, 0
    try:
        with open(os.path.join(d, f"{task_id}.log")) as f:
            data = json.load(f)
        turns = int(data.get("num_turns") or 0)
        cost = float(data.get("total_cost_usd") or 0)
        usage = data.get("usage") or {}
        tokens = sum(int(usage.get(k) or 0) for k in (
            "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    except (OSError, ValueError, TypeError):
        pass  # escalated but no readable result (still running, or claude crashed)
    return 1, turns, cost, tokens


def merged(repo, branch):
    if not repo or not branch:
        return None
    ok = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"refs/heads/{branch}"],
                        capture_output=True).returncode == 0
    if not ok:
        return None
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", f"refs/heads/{branch}", "main"],
                          capture_output=True).returncode == 0


def run_stats(conn, ids):
    now = int(time.time())
    q = ",".join("?" * len(ids))
    secs, runs, failed, blocked = 0, 0, 0, 0
    for started, ended, outcome in conn.execute(
            f"select started_at, ended_at, outcome from task_runs where task_id in ({q})", ids):
        runs += 1
        if started is not None:
            secs += max(0, (now if ended is None else ended) - started)
        if outcome in FAILED:
            failed += 1
        elif outcome == "blocked":
            blocked += 1
    return secs, runs, failed, blocked


def tickets(conn, state, repo):
    rows = conn.execute(
        "select id, title, status, assignee, workspace_kind, workspace_path, branch_name, created_at "
        "from tasks where workspace_kind in ('worktree', 'dir') and workspace_path is not null "
        "order by created_at").fetchall()
    groups = {}
    for r in rows:
        groups.setdefault(r[5], []).append(r)
    out = []
    for path, tasks in groups.items():
        builds = [t for t in tasks if t[4] == "worktree"]
        if not builds:
            continue
        build = builds[-1]  # a rebuilt ticket keeps the latest build task
        ids = [t[0] for t in tasks]
        secs, runs, failed, blocked = run_stats(conn, ids)
        esc = [escalation(state, i) for i in ids]
        qa_done = any(t[3] and t[3].endswith("qa") and t[2] == "done" for t in tasks)
        still_open = any(t[2] in OPEN for t in tasks)
        integrate = build[1].startswith("Integrate:")
        delivered = (qa_done or (integrate and build[2] == "done")) and not still_open
        out.append({
            "id": build[0], "title": build[1], "branch": build[6], "created": build[7],
            "delivered": delivered, "merged": merged(repo, build[6]),
            "minutes": secs / 60, "runs": runs, "failed": failed, "blocked": blocked,
            "escalations": sum(e[0] for e in esc), "claude_turns": sum(e[1] for e in esc),
            "claude_usd": sum(e[2] for e in esc), "claude_tokens": sum(e[3] for e in esc),
        })
    return out


def planning(conn):
    ids = [r[0] for r in conn.execute("select id from tasks where workspace_kind = 'scratch'")]
    return run_stats(conn, ids) if ids else (0, 0, 0, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--repo", default="")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not os.path.exists(a.db):
        sys.exit(f"no board database at {a.db}")
    conn = connect(a.db)
    rows = tickets(conn, a.state, a.repo)
    plan = planning(conn)
    conn.close()
    shown = rows if a.all else [r for r in rows if r["delivered"]]
    if a.json:
        print(json.dumps({"tickets": shown, "planning": dict(zip(("seconds", "runs", "failed", "blocked"), plan))}))
        return

    def state_of(r):
        if r["merged"]:
            return "merged"
        return "qa-passed" if r["delivered"] else "open"

    hdr = f"  {'task':<11} {'state':<9} {'agent min':>9} {'runs':>4} {'fail':>4} {'blk':>3} {'esc':>3} {'claude $':>8} {'tokens':>8}  title"
    print(hdr)
    for r in shown:
        print(f"  {r['id']:<11} {state_of(r):<9} {r['minutes']:9.0f} {r['runs']:4d} {r['failed']:4d} {r['blocked']:3d} "
              f"{r['escalations']:3d} {r['claude_usd']:8.2f} {r['claude_tokens']:8d}  {r['title'][:50]}")
    if not shown:
        print("  (no delivered tickets yet; --all shows open ones)")
    t = {k: sum(r[k] for r in shown) for k in ("minutes", "runs", "failed", "blocked", "escalations", "claude_usd", "claude_tokens")}
    n = len(shown)
    print(f"  {'total':<11} {str(n) + ' tickets':<9} {t['minutes']:9.0f} {t['runs']:4d} {t['failed']:4d} {t['blocked']:3d} "
          f"{t['escalations']:3d} {t['claude_usd']:8.2f} {t['claude_tokens']:8d}")
    if n:
        waste = 100 * t["failed"] / t["runs"] if t["runs"] else 0
        print(f"  per ticket: {t['minutes'] / n:.0f} agent min, {t['runs'] / n:.1f} runs, "
              f"${t['claude_usd'] / n:.2f} Claude; {waste:.0f}% of runs failed (crashed, timed out, reclaimed, gave up)")
    print(f"  planning: {plan[0] / 60:.0f} agent min over {plan[1]} runs ({plan[2]} failed)")


if __name__ == "__main__":
    main()
