#!/usr/bin/env python3
"""Factory configuration: factory.toml, with factory.conf as a deprecated fallback.

One table (KEYS) is the single source of truth for every setting: its TOML
location, the shell variable the bash scripts use, its type and its default.

    python3 -I lib/config.py shell   <factory-root>   # KEY='value' lines for bash (eval)
    python3 -I lib/config.py env     <factory-root>   # only the env overrides, as KEY='value'
    python3 -I lib/config.py show    <factory-root>   # effective values and where each came from
    python3 -I lib/config.py migrate <factory-root> [--write] [--force]
    python3 -I lib/config.py set     <factory-root> <VAR> <value>   # edit one line of factory.toml
    python3 -I lib/config.py example                  # factory.example.toml, from KEYS

Python consumers (factory_watch.py, the factory-guard plugin) import load().

Precedence: environment (only keys marked env=True) > factory.toml > defaults.
Without factory.toml, lib/common.sh sources factory.conf over the defaults and
then reapplies the environment overrides, and warns that factory.conf is
deprecated. Secrets never belong here: keys that look like tokens are refused.
"""
import os
import re
import shlex
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:
        tomllib = None

# (toml path, shell var, type, default, env-overridable, description)
# types: str, int, float, bool (shell 1/0), words (list -> space-joined), csv (list -> comma-joined)
KEYS = [
    ("target.repo", "TARGET_REPO", "str", "", False,
     "The repository the factory works on. Each build task gets a worktree under <repo>/.worktrees/."),
    ("board.slug", "BOARD", "str", "software-factory", False, "Kanban board used only by the factory."),
    ("board.name", "BOARD_NAME", "str", "Software Factory", False, "Display name of the board."),
    ("board.profile_prefix", "PROFILE_PREFIX", "str", "sf-", False, "Role profiles are named <prefix><role>."),
    ("board.roles", "ROLES", "words", ["planner", "backend", "frontend", "reviewer", "security", "qa", "integrator"],
     False, "Roles that get a Hermes profile."),
    ("guardrails.max_in_progress", "MAX_IN_PROGRESS", "int", 2, False, "Tasks running at once across the board."),
    ("guardrails.max_in_progress_per_profile", "MAX_IN_PROGRESS_PER_PROFILE", "int", 1, False,
     "Workers per role at a time."),
    ("guardrails.failure_limit", "FAILURE_LIMIT", "int", 2, False, "Consecutive failures before a task is blocked."),
    ("models.builder", "BUILDER_MODEL", "str", "", False,
     "Model for the Backend and Frontend builders (empty = the default profile's)."),
    ("models.integrator", "INTEGRATOR_MODEL", "str", "", False, "Model for the Integrator (empty = models.builder)."),
    ("models.omlx_url", "OMLX_URL", "str", "", True,
     "Model server root for factory.sh health (empty = Hermes's model.base_url without /v1)."),
    ("check.timeout", "CHECK_TIMEOUT", "int", 1800, True, "Seconds for ./check.sh in factory.sh check (0 = no limit)."),
    ("check.smoke_timeout", "SMOKE_TIMEOUT", "int", 900, True, "Seconds for factory.sh smoke (0 = no limit)."),
    ("check.scanners", "SCANNERS", "csv", ["gitleaks", "semgrep"], True,
     "Security scanners the check gate runs ([] = none). Missing ones are skipped with a warning."),
    ("check.semgrep_config", "SEMGREP_CONFIG", "str", "p/default", True, "semgrep ruleset."),
    ("check.security_role", "SECURITY_ROLE", "bool", False, True,
     "Also put a sf-security model check between build and QA."),
    ("escalation.auto", "ESCALATE_AUTO", "bool", False, False,
     "factory-watch escalates compile failures to Claude Code, once per task."),
    ("escalation.max_turns", "ESCALATE_MAX_TURNS", "int", 40, False, "Turn limit per escalation."),
    ("escalation.max_budget_usd", "ESCALATE_MAX_BUDGET_USD", "float", 5, False, "Hard spend limit per escalation."),
    ("discord.guild_id", "DISCORD_GUILD_ID", "str", "", False, "Discord server ID (written by factory.sh discord)."),
    ("discord.alerts_channel", "DISCORD_NOTIFY_CHANNEL", "str", "", False, "#factory-alerts channel ID."),
    ("watch.stale_minutes", "WATCH_STALE_MINUTES", "int", 20, False,
     "factory-watch: a running task whose log hasn't changed this long is STALLED."),
    ("watch.blocked_minutes", "WATCH_BLOCKED_MINUTES", "int", 30, False,
     "factory-watch: a task blocked this long is BLOCKED-OVER-N-MIN."),
]
# discord.channels.<role> -> DISCORD_CHANNEL_<ROLE>, for any role.
CHANNEL_SECTION = "discord.channels"
SECRET = re.compile(r"token|secret|passw|api_?key|credential", re.I)
SECTIONS = ["target", "board", "guardrails", "models", "check", "escalation", "discord", "watch"]


class ConfigError(Exception):
    pass


def _by_path():
    return {k[0]: k for k in KEYS}


def _by_var():
    return {k[1]: k for k in KEYS}


def _check_type(path, typ, value):
    ok = {
        "str": isinstance(value, str),
        "int": isinstance(value, int) and not isinstance(value, bool),
        "float": isinstance(value, (int, float)) and not isinstance(value, bool),
        "bool": isinstance(value, bool),
        "words": isinstance(value, list) and all(isinstance(v, str) for v in value),
        "csv": isinstance(value, list) and all(isinstance(v, str) for v in value),
    }[typ]
    if not ok:
        want = {"words": "a list of strings", "csv": "a list of strings"}.get(typ, typ)
        raise ConfigError(f"{path} must be {want}, got {value!r}")


def _flatten(data, prefix=""):
    for key, value in data.items():
        path = f"{prefix}{key}"
        if SECRET.search(key):
            raise ConfigError(f"{path}: secrets don't belong in factory.toml (keep tokens in ~/.hermes/.env)")
        if isinstance(value, dict):
            yield from _flatten(value, path + ".")
        else:
            yield path, value


def read_toml(path):
    if tomllib is None:
        raise ConfigError("reading factory.toml needs Python 3.11+ (tomllib) or the tomli package")
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    known = _by_path()
    values = {}
    for p, value in _flatten(data):
        if p.startswith(CHANNEL_SECTION + "."):
            role = p[len(CHANNEL_SECTION) + 1:]
            if not re.fullmatch(r"[a-z][a-z0-9_]*", role):
                raise ConfigError(f"{p}: role names are lowercase letters, digits and _")
            if not isinstance(value, str):
                raise ConfigError(f"{p} must be a string (Discord IDs are quoted: \"1234...\")")
            values[f"DISCORD_CHANNEL_{role.upper()}"] = value
            continue
        if p not in known:
            raise ConfigError(f"{path}: unknown setting {p}")
        _, var, typ, _, _, _ = known[p]
        _check_type(p, typ, value)
        values[var] = value
    return values


def to_shell(typ, value):
    if typ == "bool":
        return "1" if value else "0"
    if typ == "words":
        return " ".join(value)
    if typ == "csv":
        return ",".join(value)
    if typ == "float" and float(value).is_integer():
        return str(int(value))
    return str(value)


def from_shell(typ, text):
    """A factory.conf / environment string -> typed value."""
    if typ == "bool":
        return text.strip() not in ("", "0", "false", "no")
    if typ == "int":
        return int(text)
    if typ == "float":
        f = float(text)
        return int(f) if f.is_integer() else f
    if typ == "words":
        return text.split()
    if typ == "csv":
        return [v for v in (s.strip() for s in text.split(",")) if v]
    return text


def env_overrides(environ=None):
    environ = os.environ if environ is None else environ
    out = {}
    for path, var, typ, _, env, _ in KEYS:
        if env and var in environ:
            try:
                out[var] = from_shell(typ, environ[var])
            except ValueError as exc:
                raise ConfigError(f"environment {var}={environ[var]!r}: not a valid {typ}") from exc
    return out


def conf_values(conf_path):
    """Source factory.conf in a clean bash and return every variable it sets."""
    script = '. "$1" >/dev/null 2>&1; set -o posix; set'
    clean = {"HOME": os.environ.get("HOME", ""), "PATH": "/usr/bin:/bin"}
    before = subprocess.run(["bash", "-c", "set -o posix; set"], capture_output=True, text=True, env=clean).stdout
    after = subprocess.run(["bash", "-c", script, "bash", conf_path], capture_output=True, text=True, env=clean).stdout

    def parse(text):
        vals = {}
        for line in text.splitlines():
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if m:
                vals[m.group(1)] = m.group(2)
        return vals

    base, new = parse(before), parse(after)
    out = {}
    for var, raw in new.items():
        if var in ("BASH_ARGC", "BASH_ARGV", "BASH_LINENO", "BASH_SOURCE", "_", "BASH_EXECUTION_STRING"):
            continue
        if base.get(var) == raw:
            continue
        try:
            parts = shlex.split(raw)
            out[var] = parts[0] if parts else ""
        except ValueError:
            out[var] = raw
    return out


def resolve(root, environ=None):
    """{var: (value, source)} for every setting, the way lib/common.sh loads them."""
    vals = {var: (default, "default") for _, var, _, default, _, _ in KEYS}
    toml_path = os.path.join(root, "factory.toml")
    conf_path = os.path.join(root, "factory.conf")
    by_var = _by_var()
    if os.path.exists(toml_path):
        for var, value in read_toml(toml_path).items():
            vals[var] = (value, "factory.toml")
    elif os.path.exists(conf_path):
        for var, raw in conf_values(conf_path).items():
            if var in by_var:
                try:
                    vals[var] = (from_shell(by_var[var][2], raw), "factory.conf")
                except ValueError:
                    raise ConfigError(f"factory.conf: {var}={raw!r} is not a valid {by_var[var][2]}")
            elif var.startswith("DISCORD_CHANNEL_"):
                vals[var] = (raw, "factory.conf")
    for var, value in env_overrides(environ).items():
        vals[var] = (value, "environment")
    return vals


def load(root, environ=None):
    """Effective settings as {shell var: typed value}, for Python consumers."""
    return {var: v for var, (v, _) in resolve(root, environ).items()}


def _typ(var):
    k = _by_var().get(var)
    return k[2] if k else "str"


def shell_lines(values):
    return [f"{var}={shlex.quote(to_shell(_typ(var), value))}" for var, value in values.items()]


# --- TOML writing (tomllib only reads) ---------------------------------------

def _toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(v) for v in value) + "]"
    s = str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{s}"'


def render_toml(values, header):
    """values: {shell var: typed value}. Every known key is written, with its description."""
    lines = [header.rstrip(), ""]
    for section in SECTIONS:
        lines.append(f"[{section}]")
        for path, var, _, default, env, desc in KEYS:
            if path.split(".")[0] != section:
                continue
            note = " Environment variable " + var + " overrides it." if env else ""
            lines.append(f"# {desc}{note}")
            lines.append(f"{path.split('.', 1)[1]} = {_toml_value(values.get(var, default))}")
        lines.append("")
        if section == "discord":
            lines.append(f"[{CHANNEL_SECTION}]")
            lines.append("# One channel per role, routed to that role's profile (written by factory.sh channels).")
            roles = values.get("ROLES", _by_var()["ROLES"][3])
            extra = sorted(v[len("DISCORD_CHANNEL_"):].lower() for v in values if v.startswith("DISCORD_CHANNEL_"))
            for role in list(roles) + [r for r in extra if r not in roles]:
                lines.append(f"{role} = {_toml_value(values.get('DISCORD_CHANNEL_' + role.upper(), ''))}")
            lines.append("")
    return "\n".join(lines)


EXAMPLE_HEADER = """# Factory settings. Copy to factory.toml (git-ignored) and edit.
# Secrets don't go here: the Discord bot token stays in ~/.hermes/.env and the
# model server's API key in ~/.hermes/config.yaml.
# ./factory.sh config show prints the effective values and where each came from."""


def migrate(root, write=False, force=False):
    conf_path = os.path.join(root, "factory.conf")
    toml_path = os.path.join(root, "factory.toml")
    if not os.path.exists(conf_path):
        raise ConfigError(f"no factory.conf in {root} to migrate")
    if os.path.exists(toml_path) and write and not force:
        raise ConfigError(f"{toml_path} already exists (use --force to overwrite it)")
    raw = conf_values(conf_path)
    by_var = _by_var()
    values, skipped = {}, []
    for var, text in raw.items():
        if SECRET.search(var):
            skipped.append(f"{var} (looks like a secret; keep it in ~/.hermes/.env)")
        elif var in by_var:
            try:
                values[var] = from_shell(by_var[var][2], text)
            except ValueError:
                raise ConfigError(f"factory.conf: {var}={text!r} is not a valid {by_var[var][2]}")
        elif var.startswith("DISCORD_CHANNEL_"):
            values[var] = text
        else:
            skipped.append(f"{var} (not a factory setting)")
    header = ("# Factory settings, migrated from factory.conf by ./factory.sh config migrate.\n"
              "# factory.conf is no longer read while this file exists; delete it when you're happy.\n"
              "# Secrets don't go here: the Discord bot token stays in ~/.hermes/.env.")
    text = render_toml(values, header)
    # Round trip: what we wrote must read back to exactly what factory.conf said.
    if tomllib is not None:
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as tmp:
            tmp.write(text)
        try:
            back = read_toml(tmp.name)
        finally:
            os.unlink(tmp.name)
        for var, value in values.items():
            if back.get(var) != value:
                raise ConfigError(f"migration would change {var}: {value!r} -> {back.get(var)!r}")
    if write:
        with open(toml_path + ".tmp", "w") as f:
            f.write(text)
        os.replace(toml_path + ".tmp", toml_path)
    return text, skipped


def set_value(root, var, text):
    """Set one setting in factory.toml by editing its line (comments survive).
    Creates factory.toml from the example if it doesn't exist."""
    toml_path = os.path.join(root, "factory.toml")
    if SECRET.search(var):
        raise ConfigError(f"{var} looks like a secret; it doesn't go in factory.toml")
    if var.startswith("DISCORD_CHANNEL_"):
        section, key, value = CHANNEL_SECTION, var[len("DISCORD_CHANNEL_"):].lower(), text
    elif var in _by_var():
        path, _, typ, _, _, _ = _by_var()[var]
        section, key = path.split(".", 1)
        value = from_shell(typ, text)
    else:
        raise ConfigError(f"unknown setting {var}")
    if not os.path.exists(toml_path):
        lines = render_toml({}, EXAMPLE_HEADER).splitlines()
    else:
        with open(toml_path) as f:
            lines = f.read().splitlines()
    new = f"{key} = {_toml_value(value)}"
    current, at, header_at = None, None, None
    for i, line in enumerate(lines):
        m = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if m:
            current = m.group(1).strip()
            if current == section:
                header_at = i
            continue
        if current == section and re.match(rf"^\s*{re.escape(key)}\s*=", line):
            at = i
    if at is not None:
        lines[at] = new
    elif header_at is not None:
        lines.insert(header_at + 1, new)
    else:
        lines += ["", f"[{section}]", new]
    text_out = "\n".join(lines) + "\n"
    with open(toml_path + ".tmp", "w") as f:
        f.write(text_out)
    try:
        back = read_toml(toml_path + ".tmp")
    except ConfigError:
        os.unlink(toml_path + ".tmp")
        raise
    if back.get(var) != value:
        os.unlink(toml_path + ".tmp")
        raise ConfigError(f"could not set {var} in {toml_path}")
    os.replace(toml_path + ".tmp", toml_path)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    try:
        if cmd == "example":
            print(render_toml({}, EXAMPLE_HEADER), end="")
            return
        root = argv[2]
        if cmd == "shell":
            if os.path.exists(os.path.join(root, "factory.toml")):
                vals = load(root)
            else:  # defaults and env only; common.sh sources factory.conf itself
                vals = {var: d for _, var, _, d, _, _ in KEYS}
                vals.update(env_overrides())
            print("\n".join(shell_lines(vals)))
            print(f"FACTORY_CONFIG_FILE={'factory.toml' if os.path.exists(os.path.join(root, 'factory.toml')) else ''}")
        elif cmd == "set":
            set_value(root, argv[3], argv[4])
        elif cmd == "env":
            print("\n".join(shell_lines(env_overrides())))
        elif cmd == "show":
            vals = resolve(root)
            width = max(len(v) for v in vals)
            for var, (value, source) in vals.items():
                print(f"  {var:<{width}}  {to_shell(_typ(var), value)!r:<40}  {source}")
        elif cmd == "migrate":
            text, skipped = migrate(root, write="--write" in argv, force="--force" in argv)
            if "--write" not in argv:
                print(text, end="")
            for s in skipped:
                print(f"not migrated: {s}", file=sys.stderr)
        else:
            sys.exit(f"unknown command {cmd}")
    except ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
