#!/usr/bin/env python3
# Factory watchdog for sf-planner's cron monitor. Prints one stable line per problem
# (no timestamps, so unchanged problems don't re-trigger the agent), or "OK".
#
# Installed to ~/.hermes/profiles/sf-planner/scripts/ by scripts/install-guard.sh.
import json, os, re, sqlite3, subprocess, time

BOARD = "software-factory"
LOGS = os.path.expanduser(f"~/.hermes/kanban/boards/{BOARD}/logs")
DB = os.environ.get("FACTORY_WATCH_DB") or os.path.expanduser(f"~/.hermes/kanban/boards/{BOARD}/kanban.db")
FACTORY = os.environ.get("FACTORY_ROOT") or os.path.expanduser("~/IdeaProjects/hermes-software-factory")
REPO = os.environ.get("FACTORY_TARGET_REPO") or os.path.expanduser("~/IdeaProjects/hermes-board")
STALE_SECS = 20 * 60
BLOCKED_LONG_SECS = 30 * 60


def kanban(*args):
    return subprocess.run(["hermes", "kanban", "--board", BOARD, *args],
                          capture_output=True, text=True, timeout=120).stdout


def tasks(status):
    out = kanban("list", "--status", status, "--json")
    try:
        data = json.loads(out)
    except ValueError:
        return []
    return data if isinstance(data, list) else data.get("tasks", [])


def git(*args, cwd=REPO):
    return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=30)


def task_branch(branch, workspace):
    """A task's branch; tasks on a dir: workspace only record the worktree path."""
    if branch:
        return branch
    if workspace and os.path.isdir(workspace):
        name = git("rev-parse", "--abbrev-ref", "HEAD", cwd=workspace).stdout.strip()
        return name if name not in ("", "HEAD", "main") else None
    return None


def unmerged(branch):
    """True when branch exists in REPO and has commits that aren't on main."""
    res = git("rev-list", "--count", f"main..refs/heads/{branch}")
    return res.returncode == 0 and res.stdout.strip() != "0"


def review_packet(qa_task):
    """Write the ticket's review packet (factory.sh packet) and say where it is."""
    try:
        res = subprocess.run([os.path.join(FACTORY, "factory.sh"), "packet", qa_task],
                             capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    except Exception:
        res = None
    m = re.search(r"Review packet: (\S+)", res.stdout if res else "")
    if not m:
        return "test-merge it into main"
    return f"review packet {os.path.relpath(m.group(1), FACTORY)}, then test-merge it into main"


def merge_problems():
    # mode=ro can't open a WAL database with no sidecar files, so use query_only.
    conn = sqlite3.connect(DB, timeout=5)
    conn.execute("PRAGMA query_only = ON")
    rows = conn.execute(
        "select id, title, status, assignee, branch_name, workspace_path from tasks where status != 'archived'"
    ).fetchall()
    found = []
    for tid, title, *_ in conn.execute(
        "select t.id, t.title, max(e.created_at) from tasks t join task_events e on e.task_id = t.id "
        "where t.status = 'blocked' and e.kind = 'blocked' group by t.id having max(e.created_at) < ?",
        (time.time() - BLOCKED_LONG_SECS,),
    ):
        found.append(f"BLOCKED-OVER-30-MIN {tid} {title}")
    conn.close()

    open_branches, qa_done, built = set(), {}, set()
    for tid, title, status, assignee, branch, workspace in rows:
        name = task_branch(branch, workspace)
        if not name or not unmerged(name):
            continue
        built.add(name)
        if status != "done":
            open_branches.add(name)
        elif assignee == "sf-qa":
            qa_done[name] = tid
    # A branch with open work on it isn't ready to merge yet.
    for name, tid in qa_done.items():
        if name not in open_branches:
            found.append(f"QA-PASSED-NOT-MERGED {name} ({tid}): {review_packet(tid)}")
    if built and not any(r[2] in ("ready", "running") for r in rows):
        found.append(f"IDLE no ready or running tasks, unmerged branches: {', '.join(sorted(built))}")
    return found


def conf(name, default=""):
    try:
        with open(os.path.join(FACTORY, "factory.conf")) as f:
            for line in f:
                m = re.match(rf"\s*{name}=\"?([^\"#\s]*)", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return default


def escalations():
    """With ESCALATE_AUTO=1, start escalate.sh for a stuck builder task with a compile error."""
    if conf("ESCALATE_AUTO", "0") != "1":
        return []
    marks = os.path.join(FACTORY, ".factory", "escalations")
    if os.path.isdir(os.path.join(marks, ".lock")):
        return []  # one at a time
    conn = sqlite3.connect(DB, timeout=5)
    conn.execute("PRAGMA query_only = ON")
    rows = conn.execute(
        "select id, title from tasks where assignee in ('sf-backend', 'sf-frontend', 'sf-integrator') "
        "and (status = 'blocked' or (consecutive_failures >= 2 and status in ('ready', 'todo')))"
    ).fetchall()
    conn.close()
    for tid, title in rows:
        log = os.path.join(LOGS, f"{tid}.log")
        if os.path.exists(os.path.join(marks, f"{tid}.marker")) or not os.path.exists(log):
            continue
        with open(log, errors="replace") as f:
            if not re.search(r"error\[E\d+\]", f.read()):
                continue
        status = subprocess.run(["claude", "auth", "status"], capture_output=True, text=True, timeout=30,
                                env={k: os.environ[k] for k in ("HOME", "USER", "PATH") if k in os.environ})
        if '"loggedIn": true' not in status.stdout:
            return [f"ESCALATION-NEEDS-LOGIN {tid} is stuck on a compile error: run claude auth login"]
        env = {k: v for k, v in os.environ.items() if k != "HERMES_HOME"}
        with open(os.devnull, "r+") as null:
            subprocess.Popen([os.path.join(FACTORY, "factory.sh"), "escalate", tid], cwd=FACTORY, env=env,
                             stdin=null, stdout=null, stderr=null, start_new_session=True)
        return [f"ESCALATED {tid} to Claude Code: {title}"]
    return []


def model_server():
    """MODELS-NOT-READY when omlx is down or a role model isn't loaded (read-only probe).
    Quiet while the factory is paused: that's when models get swapped."""
    if os.path.exists(os.path.join(FACTORY, ".factory", "paused-tasks.txt")):
        return []
    try:
        res = subprocess.run([os.path.join(FACTORY, "scripts", "health.sh"), "--quiet"],
                             capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except Exception as exc:
        return [f"MODELS-NOT-READY health check failed to run: {exc}"]
    if res.returncode == 0:
        return []
    first = (res.stderr.strip().splitlines() or ["unknown"])[0].removeprefix("health: ")
    return [f"MODELS-NOT-READY {first}: run ./factory.sh pause until it is fixed"]


problems = merge_problems() + escalations() + model_server()
for t in tasks("blocked"):
    problems.append(f"BLOCKED {t['id']} ({t.get('assignee')}) {t.get('title')}")

for t in tasks("running"):
    tid = t["id"]
    log = os.path.join(LOGS, f"{tid}.log")
    if os.path.exists(log) and time.time() - os.path.getmtime(log) > STALE_SECS:
        problems.append(f"STALLED {tid} ({t.get('assignee')}) log unchanged >20 min: {t.get('title')}")
    if os.path.exists(log):
        with open(log, errors="replace") as f:
            cmds = [re.sub(r"\s+[0-9.]+s.*$", "", l).strip() for l in f if "💻 $" in l][-6:]
        if len(cmds) == 6 and len(set(cmds)) == 1:
            problems.append(f"LOOPING {tid} ({t.get('assignee')}) repeating: {cmds[0].split('$', 1)[-1].strip()[:80]}")
    runs = kanban("runs", tid)
    outcomes = [l.split()[1] for l in runs.splitlines() if re.match(r"\s+\d+\s+\S", l)]
    if len(outcomes) >= 3 and outcomes[-3:-1] == ["crashed", "crashed"]:
        problems.append(f"CRASHING {tid} ({t.get('assignee')}) last two runs crashed: {t.get('title')}")

print("\n".join(sorted(problems)) if problems else "OK")
