# Hermes software factory

Bash automation for the setup in Raell Dottin's article [Building a Software Factory in Hermes](https://medium.com/@raell.dottin/building-a-software-factory-in-hermes-d8ce546626e8). It builds a small team of Hermes agents around a durable kanban board, with Discord as the control panel.

```
feature request ─▶ Planner ─▶ (you approve) ─▶ Backend / Frontend build ─▶ Reviewer
                                                  own worktree + branch      │ approve / request changes
                                                                             ▼
                                                                 Security check ─▶ QA ─▶ you merge
```

## What it sets up

| Article concept | Here |
|---|---|
| Durable Kanban board | A dedicated `software-factory` board (your other boards are untouched) |
| Profiles per role | `sf-planner`, `sf-backend`, `sf-frontend`, `sf-reviewer`, `sf-security`, `sf-qa`, each with a role prompt from `roles/` as its `SOUL.md` |
| Planner never codes | `sf-planner` has terminal, file, code execution and delegation tools disabled |
| Git worktree per task | Every build task runs in `<repo>/.worktrees/<task>` on its own `factory/...` branch |
| Independent review and security | Separate profiles and contexts; the builder never has the last word |
| Low concurrency | 2 tasks running at most, 1 per role, blocked after 2 consecutive failures |
| Auto-decomposition off | `kanban.auto_decompose=false`; you approve each plan with `./factory.sh approve` |
| Quiet routine updates | No wake-on-completion; tasks post passive notices to `#factory-alerts` |
| Discord gateway | One bot, mention-only, only your user ID, ignores other bots. `#factory-alerts` gets task notices; `#planner`, `#backend`, … are routed to each role profile with `gateway.profile_routes` |
| Builders commit, judges don't edit | The `factory-guard` Hermes plugin commits any uncommitted builder work when the Reviewer starts and hands self-reviews to the Reviewer. Reviewer, Security and QA have no file-editing tools |
| ECC shared memory | `.ecc/memory/` Markdown notes in the target repo, read by every agent |

## Quick start

```bash
cp factory.conf.example factory.conf     # set TARGET_REPO
./factory.sh init                        # board, profiles, guardrails, .ecc/memory
./factory.sh discord                     # interactive; you paste the bot token
./factory.sh channels                    # one Discord channel per role (rerun anytime)
./factory.sh doctor                      # everything green?

./factory.sh feature "Add CSV export to the reports page"
./factory.sh status                      # wait for the Planner task to finish
./factory.sh approve t_xxxxxxxx          # review/edit the plan, then create tasks
```

Every command accepts `--dry-run`, and `init` is safe to rerun.

## Commands

| Command | What it does |
|---|---|
| `init`, `discord`, `channels`, `doctor` | Setup (see Quick start) |
| `feature "<goal>" [--details "..."]` | Ask the Planner for a plan |
| `approve <plan-task>` | Review the plan, then create build → security → QA tasks |
| `check <worktree>` | Run `./check.sh` (limited to `CHECK_TIMEOUT`) and record a pass for HEAD; hand-offs need it |
| `smoke <worktree>` | Build, start and exercise the backend/frontend (limited to `SMOKE_TIMEOUT`) |
| `reap [<worktree>...] [--force]` | Stop processes left running in task worktrees (`trunk serve`, debug backends). Without paths: every task worktree on the board, never other checkouts. Skips live kanban workers unless `--force` |
| `integrate <build-task> ["what failed"]` | Hand a branch that won't merge cleanly to the Integrator |
| `escalate <task> ["note"]` | Hand a stuck build task to headless Claude Code, then back to review |
| `status` | Blocked, in review, running, ready |
| `teardown` | Archive the board, delete factory profiles, restore settings |

## Things to know

- **Guardrails are global.** Hermes reads the kanban limits from `~/.hermes/config.yaml`, so they also apply to your other boards. `configure-guardrails.sh` saves the old values in `.factory/` and `teardown` restores them.
- **Profiles clone `default`.** They use its model and API keys but not its messaging channels, so only the default gateway talks to Discord.
- **Builds run one after another.** Each build task depends on the previous one, so branches stack cleanly. Security and QA for one task can run while the next task builds.
- **Checks have hard limits.** `check` and `smoke` run in their own process group under `CHECK_TIMEOUT` / `SMOKE_TIMEOUT` (`factory.conf`). On timeout the gate fails with exit 124 and records nothing; whatever they started is killed when they end, so no `trunk serve` or debug backend outlives a run.
- **You merge.** Agents commit on their task branch and never push or merge. When QA passes, merge the `factory/...` branch yourself.
- **Teardown** archives the board, deletes the `sf-*` profiles and restores kanban settings. It leaves Discord settings (a backup of `.env` is in `.factory/`) and task branches alone.

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
factory.conf.example       settings; copy to factory.conf
.factory/                  local state: backups, what was created, approved plans
```
