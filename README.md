# Hermes software factory

Bash automation for the setup in Raell Dottin's article [Building a Software Factory in Hermes](https://medium.com/@raell.dottin/building-a-software-factory-in-hermes-d8ce546626e8). It builds a small team of Hermes agents around a durable kanban board, with Discord as the control panel.

```
feature request ─▶ Planner ─▶ (you approve) ─▶ Backend / Frontend build ─▶ Reviewer
small ticket ──────(factory.sh ticket)──────▶  own worktree + branch      │ approve / request changes
                                                                             ▼
                                              check gate (check.sh, gitleaks, semgrep) ─▶ QA ─▶ you merge
```

## What it sets up

| Article concept | Here |
|---|---|
| Durable Kanban board | A dedicated `software-factory` board (your other boards are untouched) |
| Profiles per role | `sf-planner`, `sf-backend`, `sf-frontend`, `sf-reviewer`, `sf-security` (optional, see below), `sf-qa`, `sf-integrator`, each with a role prompt from `roles/` as its `SOUL.md` |
| Planner never codes | `sf-planner` has terminal, file, code execution and delegation tools disabled |
| Git worktree per task | Every build task runs in `<repo>/.worktrees/<task>` on its own `factory/...` branch |
| Independent review and security | Separate profiles and contexts; the builder never has the last word. Security is gitleaks + semgrep in the check gate; the `sf-security` model role is optional (`check.security_role = true`) |
| Low concurrency | 2 tasks running at most, 1 per role, blocked after 2 consecutive failures |
| Auto-decomposition off | `kanban.auto_decompose=false`; you approve each plan with `./factory.sh approve` |
| Quiet routine updates | No wake-on-completion; tasks post passive notices to `#factory-alerts` |
| Discord gateway | One bot, mention-only, only your user ID, ignores other bots. `#factory-alerts` gets task notices; `#planner`, `#backend`, … are routed to each role profile with `gateway.profile_routes` |
| Builders commit, judges don't edit | The `factory-guard` Hermes plugin commits any uncommitted builder work when the Reviewer starts and hands self-reviews to the Reviewer. Reviewer, Security and QA have no file-editing tools |
| ECC shared memory | `.ecc/memory/` Markdown notes in the target repo, read by every agent |

## Quick start

```bash
cp factory.example.toml factory.toml     # set target.repo
./factory.sh init                        # board, profiles, guardrails, .ecc/memory
./factory.sh discord                     # interactive; you paste the bot token
./factory.sh channels                    # one Discord channel per role, incl. #integrator (rerun anytime)
./factory.sh doctor                      # everything green?

./factory.sh feature "Add CSV export to the reports page"
./factory.sh status                      # wait for the Planner task to finish
./factory.sh approve t_xxxxxxxx          # review/edit the plan, then create tasks
```

Every command accepts `--dry-run`, and `init` is safe to rerun.

## Settings

Everything lives in one `factory.toml` (git-ignored; start from `factory.example.toml`), in sections `[target]`, `[board]`, `[guardrails]`, `[models]`, `[check]`, `[escalation]`, `[discord]` (+ `[discord.channels]`) and `[watch]`. The bash scripts, `factory_watch.py` and the factory-guard plugin all read it through `lib/config.py`, which holds every key's type and default and rejects unknown keys and anything that looks like a secret. The Discord bot token stays in `~/.hermes/.env` and the model server's API key in `~/.hermes/config.yaml`. Role prompts get the factory path and model-server port filled in when profiles are created, so nothing machine-specific is hardcoded.

- `./factory.sh config show`: every setting's effective value and where it came from (default, factory.toml, factory.conf, environment).
- `./factory.sh config migrate`: writes `factory.toml` from an old `factory.conf` and leaves `factory.conf` untouched (`--dry-run` prints it). Without a `factory.toml`, `factory.conf` is still read, with a deprecation warning.
- Environment variables still override `CHECK_TIMEOUT`, `SMOKE_TIMEOUT`, `OMLX_URL`, `SCANNERS`, `SEMGREP_CONFIG` and `SECURITY_ROLE` for one command.
- `factory.sh discord` and `channels` write channel IDs into `factory.toml`.

Settings the factory pushes into Hermes (`configure-guardrails.sh` sets `kanban.*` in `~/.hermes/config.yaml`; `channels` sets `gateway.profile_routes`) are derived from `factory.toml` and reapplied by `init` / `channels`.

## Commands

| Command | What it does |
|---|---|
| `init`, `discord`, `channels`, `doctor` | Setup (see Quick start) |
| `feature "<goal>" [--details "..."]` | Ask the Planner for a plan |
| `approve <plan-task>` | Review the plan, then create build → security → QA tasks |
| `ticket "<title>" --done-when "<cmd>" [--role backend\|frontend] [--details "..."]` | Fast lane for small tickets: no Planner, no approve step. Creates one build → security → QA chain. The check gate runs `<cmd>` in the worktree after `./check.sh`, and hand-offs need both to pass |
| `check <worktree>` | Run `./check.sh` (limited to `CHECK_TIMEOUT`) and record a pass for HEAD; hand-offs need it |
| `smoke <worktree>` | Build, start and exercise the backend/frontend (limited to `SMOKE_TIMEOUT`) |
| `reap [<worktree>...] [--force]` | Stop processes left running in task worktrees (`trunk serve`, debug backends). Without paths: every task worktree on the board, never other checkouts. Skips live kanban workers unless `--force` |
| `pause ["reason"]` | Hold every card that could start a worker (todo/ready/running via `kanban schedule`; review cards are reopened and scheduled), stop their workers, reap leftovers, and record each card in `.factory/paused-tasks.txt`. Blocked cards are left alone |
| `resume [--force]` | Run `health`, then release exactly the cards `pause` held (review cards go back to the Reviewer). Cards blocked before the pause stay blocked. `--force` skips the health check |
| `health` | Read-only model-server check: omlx answers, and each role's model is loaded and not loading. Never loads or unloads anything |
| `packet <task> [--pr]` | Review packet for a QA-passed ticket: `.factory/review/<build>.md` with the ticket, done-when, check-gate record, whether it merges cleanly (`git merge-tree`), diff stat, commits, and the Reviewer's and QA's summaries (QA's includes the smoke output). `--pr` also pushes the branch and opens a draft PR, only with a GitHub `origin` and `gh` logged in. The factory-watch cron writes one for every QA-passed, unmerged branch |
| `integrate <build-task> ["what failed"]` | Hand a branch that won't merge cleanly to the Integrator (see below) |
| `escalate <task> ["note"]` | Hand a stuck build task to headless Claude Code, then back to review |
| `status [--cost] [--all]` | Blocked, in review, running, ready; then the cost of each delivered ticket. `--cost` shows only the cost table, `--all` adds open tickets |
| `teardown` | Archive the board, delete factory profiles, restore settings |

## Things to know

- **Guardrails are global.** Hermes reads the kanban limits from `~/.hermes/config.yaml`, so they also apply to your other boards. `configure-guardrails.sh` saves the old values in `.factory/` and `teardown` restores them.
- **Profiles clone `default`.** They use its model and API keys but not its messaging channels, so only the default gateway talks to Discord.
- **Builds run one after another.** Each build task depends on the previous one, so branches stack cleanly. Security and QA for one task can run while the next task builds.
- **Checks have hard limits.** `check` and `smoke` run in their own process group under `check.timeout` / `check.smoke_timeout` (`factory.toml`). On timeout the gate fails with exit 124 and records nothing; whatever they started is killed when they end, so no `trunk serve` or debug backend outlives a run.
- **Pause before touching models.** Reloading a model in oMLX crashes the workers using it; most wasted runs came from that. Run `./factory.sh pause`, change models, then `./factory.sh resume`, which refuses until `health` passes. `feature` and `approve` also refuse while the model server isn't ready (`FACTORY_SKIP_HEALTH=1` overrides), and the factory-watch cron reports `MODELS-NOT-READY`. Hermes has no hook that can veto a dispatch, so these are the gates. Pause uses `schedule`, not `block`: Hermes sends a card to triage the second time it is blocked for the same reason.
- **Fast lane.** `./factory.sh ticket "Return 404 JSON for unknown boards" --done-when "cargo test -p hermes-board-backend unknown_board"` skips planning. The done-when command is stored in `.factory/done-when/<worktree>`, outside the repo where the builder can't change it. Its passes are recorded per worktree (`check-pass/<sha>@<worktree>`), so a pass for the same commit elsewhere doesn't count.
- **Security is scanners, not a model.** Every `check` runs gitleaks (secrets in `main..HEAD`, output redacted) and semgrep (`check.semgrep_config` on the changed files, metrics off) after `./check.sh`; a finding fails the gate. Install them with `brew install gitleaks semgrep`; until then the gate warns and skips them. The `sf-security` model role ran 29 times without a finding, so `approve` and `ticket` only create a security-check task with `check.security_role = true`.
- **What a ticket cost.** `./factory.sh status --cost` lists each delivered ticket (QA passed; `merged` once its branch is on main) with agent minutes, runs, failed runs (crashed, timed out, reclaimed, gave up), runs that ended blocked, Claude escalations and their dollars/tokens (from `.factory/escalations/<task>.log`), plus totals and planning time. A ticket is everything run in its build worktree: build, review, security and QA. It reads the board DB read-only.
- **You merge.** Agents commit on their task branch and never push or merge. When QA passes, merge the `factory/...` branch yourself.
- **Teardown** archives the board, deletes the `sf-*` profiles and restores kanban settings. It leaves Discord settings (a backup of `.env` is in `.factory/`) and task branches alone.

## Merging and the Integrator

When QA passes, read `.factory/review/<build>.md` (`./factory.sh packet <task>` writes it on demand). If it says the branch merges cleanly, merge it yourself. If it lists conflicts, run `./factory.sh integrate <build-task>`. The `sf-integrator` profile (`roles/integrator.md`, coder model `INTEGRATOR_MODEL`, default `BUILDER_MODEL`) gets its own worktree on `integrate/<slug>` cut from main. It merges the branch, resolves conflicts so both sides survive, and gets `./check.sh` passing. It never adds features or merges into main, and it blocks with a question when a conflict needs a design decision. Its task notices go to `#integrator`, which needs a Discord channel: create it, then rerun `./factory.sh channels`. You still merge `integrate/<slug>`.

## Layout

```
factory.sh                 entry point
lib/common.sh              shared helpers, config loading, --dry-run
lib/run-limited.pl         run a command in its own process group with a hard time limit
scripts/                   one script per step
roles/*.md                 role prompts (become each profile's SOUL.md)
hermes-plugin/factory-guard/  dispatcher hooks installed by init
templates/memory/*.md      seed files for .ecc/memory/
tests/test-*.sh            unit-style tests (no board or model needed): for t in tests/test-*.sh; do $t; done
lib/config.py              every setting, its default and type; loads factory.toml for bash and Python
factory.example.toml       settings; copy to factory.toml (generated: ./factory.sh config example)
.factory/                  local state: backups, what was created, approved plans
```
