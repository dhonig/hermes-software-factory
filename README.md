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

## Things to know

- **Guardrails are global.** Hermes reads the kanban limits from `~/.hermes/config.yaml`, so they also apply to your other boards. `configure-guardrails.sh` saves the old values in `.factory/` and `teardown` restores them.
- **Profiles clone `default`.** They use its model and API keys but not its messaging channels, so only the default gateway talks to Discord.
- **Builds run one after another.** Each build task depends on the previous one, so branches stack cleanly. Security and QA for one task can run while the next task builds.
- **You merge.** Agents commit on their task branch and never push or merge. When QA passes, merge the `factory/...` branch yourself.
- **Teardown** archives the board, deletes the `sf-*` profiles and restores kanban settings. It leaves Discord settings (a backup of `.env` is in `.factory/`) and task branches alone.

## Layout

```
factory.sh                 entry point
lib/common.sh              shared helpers, config loading, --dry-run
scripts/                   one script per step
roles/*.md                 role prompts (become each profile's SOUL.md)
templates/memory/*.md      seed files for .ecc/memory/
factory.conf.example       settings; copy to factory.conf
.factory/                  local state: backups, what was created, approved plans
```
