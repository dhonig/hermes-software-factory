"""Software factory guardrails for the Hermes kanban dispatcher.

Small local models don't reliably follow the workflow, so two steps are
enforced here instead of trusted to the prompt:

1. When the Reviewer starts on a task, any uncommitted work in the task's git
   worktree is committed first, so the review, security check and QA all see
   a real branch diff and there is something to merge.
2. When a builder is spawned to review its own task (it requested review
   without naming a reviewer), the review is handed to the Reviewer.
3. The Reviewer, Security and QA profiles cannot call kanban_request_review.
   They kept requesting review of their own task, which sent it straight back
   to them; they must finish with complete, block or request_changes.
4. The backend and frontend builders cannot call kanban_complete: they must hand
   off with kanban_request_review, so review, security and QA always run. The
   Integrator is exempt; its tasks complete after ./check.sh and a person merges.
5. No hand-off without a real ./check.sh pass. Builders and the Integrator can't
   request review, and the Reviewer, Security, QA and Integrator can't complete,
   unless `factory.sh check` recorded a pass for the worktree's current HEAD.
   Models kept reporting passes for code that had never compiled.
6. The Reviewer, Security and QA can't change a worktree from the terminal
   (git add/commit, sed -i, redirects into source files). They have no file
   tools, but one rewrote a stylesheet from the shell and another committed it.

Only acts on the factory board and its profiles (see FACTORY_* below).
"""

import logging
import os
import re
import sqlite3
import subprocess
import threading
from pathlib import Path

log = logging.getLogger("factory-guard")

BOARD = os.environ.get("FACTORY_BOARD", "software-factory")
PREFIX = os.environ.get("FACTORY_PROFILE_PREFIX", "sf-")
REVIEWER = PREFIX + "reviewer"
BUILDERS = {PREFIX + "backend", PREFIX + "frontend"}
CHECKERS = {PREFIX + "reviewer", PREFIX + "security", PREFIX + "qa"}
INTEGRATOR = PREFIX + "integrator"
# git merge and git merge --abort stay allowed: QA's trial merge needs them.
WRITE_COMMAND = re.compile(
    r"\bgit\s+(add|commit|rm|mv|restore|stash|reset|revert|cherry-pick|apply)\b"
    r"|\bgit\s+checkout\s+--"
    r"|\bsed\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*i"
    r"|\bperl\s+-[a-zA-Z]*i"
    r"|\btee\b"
    r"|>>?\s*[\"']?[^\s\"'|&;]*\.(rs|css|html|toml|lock|md|py|sh|js|json|yaml|yml)\b"
)
BUILD_DIRS = ("target", "node_modules", "dist", "build", ".venv", "__pycache__", ".idea")


def _hermes_bin() -> str:
    return os.environ.get("HERMES_BIN") or "hermes"


def _git(cwd: str, *args: str, timeout: int = 20) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=timeout)


def _task_status(board: str, task_id: str) -> str | None:
    db = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / "kanban" / "boards" / board / "kanban.db"
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2) as conn:
            row = conn.execute("select status from tasks where id = ?", (task_id,)).fetchone()
        return row[0] if row else None
    except Exception as exc:  # never break dispatch over a guard
        log.debug("factory-guard: status lookup failed for %s: %s", task_id, exc)
        return None


def _commit_builder_work(task_id: str, workspace: str) -> None:
    if not workspace or not (Path(workspace) / ".git").exists():
        return
    try:
        if not _git(workspace, "status", "--porcelain").stdout.strip():
            return
        # Never sweep build output into the commit, even if the repo forgot to ignore it.
        _git(workspace, "add", "-A", "--", ".", *(f":(exclude,glob)**/{d}/**" for d in BUILD_DIRS))
        if not _git(workspace, "diff", "--cached", "--name-only").stdout.strip():
            return
        msg = f"factory: builder changes for {task_id}\n\nCommitted automatically before review."
        res = _git(workspace, "-c", "user.name=Hermes Factory", "-c", "user.email=factory@localhost",
                   "commit", "-q", "-m", msg)
        if res.returncode == 0:
            log.info("factory-guard: committed uncommitted builder work in %s for %s", workspace, task_id)
        else:
            log.warning("factory-guard: commit failed for %s: %s", task_id, (res.stderr or res.stdout).strip())
    except Exception as exc:
        log.warning("factory-guard: could not commit work for %s: %s", task_id, exc)


def _reroute_review(board: str, task_id: str) -> None:
    try:
        subprocess.run(
            [_hermes_bin(), "kanban", "--board", board, "request-review", task_id,
             "--reviewer", REVIEWER, "--force",
             "--summary", f"Rerouted to {REVIEWER}: review was requested without naming a reviewer."],
            capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
        )
        log.info("factory-guard: rerouted review of %s to %s", task_id, REVIEWER)
    except Exception as exc:
        log.warning("factory-guard: could not reroute %s: %s", task_id, exc)


def _on_spawned(task_id=None, board=None, assignee=None, workspace_path=None, **_kw):
    if board != BOARD or not task_id:
        return
    if assignee == REVIEWER:
        _commit_builder_work(task_id, workspace_path or "")
    elif assignee in BUILDERS and _task_status(board, task_id) == "review":
        # Off the dispatch lock: rerouting shells out to the hermes CLI.
        threading.Thread(target=_reroute_review, args=(board, task_id), daemon=True).start()


def _current_profile() -> str:
    home = Path(os.environ.get("HERMES_HOME", "")).resolve()
    return home.name if home.parent.name == "profiles" else ""


def _factory_root() -> Path | None:
    # Written by scripts/install-guard.sh next to this file.
    try:
        return Path(Path(__file__).with_name("factory_root").read_text().strip())
    except OSError:
        return None


def _check_gate() -> dict | None:
    """Block unless ./check.sh passed on the task worktree's HEAD; None to allow."""
    workspace = os.environ.get("HERMES_KANBAN_WORKSPACE", "")
    root = _factory_root()
    if not workspace or root is None or not (Path(workspace) / "check.sh").exists():
        return None  # not a factory build worktree, nothing to gate
    try:
        res = _git(workspace, "rev-parse", "HEAD")
    except Exception as exc:  # never wedge a worker over a guard failure
        log.warning("factory-guard: rev-parse failed in %s: %s", workspace, exc)
        return None
    sha = res.stdout.strip()
    if res.returncode != 0 or not sha or (root / ".factory" / "check-pass" / sha).exists():
        return None
    return {
        "action": "block",
        "message": (
            f"check.sh has not passed on {sha}; run it in the foreground: "
            f"{root}/factory.sh check {workspace}"
        ),
    }


def _on_pre_tool_call(tool_name=None, args=None, **_kw):
    profile = _current_profile()
    if tool_name == "terminal" and profile in CHECKERS:
        command = (args or {}).get("command") or ""
        if WRITE_COMMAND.search(command):
            return {
                "action": "block",
                "message": (
                    "Reviewer, security and QA must not change the worktree. If something needs "
                    "fixing, finish with kanban_request_changes or kanban_block and the exact finding."
                ),
            }
    if (tool_name == "kanban_request_review" and profile in BUILDERS | {INTEGRATOR}) or (
        tool_name == "kanban_complete" and profile in CHECKERS | {INTEGRATOR}
    ):
        return _check_gate()
    if tool_name == "kanban_complete" and profile in BUILDERS:
        return {
            "action": "block",
            "message": (
                "kanban_complete is not available to builders: your work must go through review. "
                "Commit, check that git diff --stat main...HEAD lists your files, then call "
                f"kanban_request_review with reviewer={REVIEWER} and a summary including the ./check.sh result."
            ),
        }
    if tool_name != "kanban_request_review" or profile not in CHECKERS:
        return None
    return {
        "action": "block",
        "message": (
            "kanban_request_review is not available to reviewer, security or QA: it sends the task "
            "back to you. Finish with kanban_complete if it passes, or kanban_request_changes / "
            "kanban_block with the exact finding if it fails."
        ),
    }


def register(ctx):
    ctx.register_hook("on_kanban_worker_spawned", _on_spawned)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
