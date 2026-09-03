# devlease

Leases each Android device and emulator to one coding agent at a time.

Run two or three agents on one Android codebase and they will eventually reach for
the same device. One installs a build while another is mid-instrumentation-run; one
resets app state under another's UI test; one runs `adb kill-server` and every other
agent's session dies. The failures are intermittent and read like flaky tests.

devlease is a `PreToolUse` hook. Before any command that touches a device, it works
out which device that is and takes an exclusive lease on it. A second agent asking
for the same device waits briefly, then gets told who holds it and to do something
else. Nothing else about how agents work changes.

## Install

**As a Claude Code plugin**

```
/plugin marketplace add ubuntudroid/devlease
/plugin install devlease
```

That wires the hook. Plugin hooks load when a session starts, so open a new
session before expecting the gate to fire.

To put the CLI on your `PATH`, point at the installed version explicitly:

```
ln -sf "$(ls -d ~/.claude/plugins/cache/devlease/devlease/*/ | tail -1)bin/devlease" ~/bin/devlease
```

Re-run that after upgrading, or clone the repo and symlink `bin/devlease` from
the clone instead, which survives version changes.

**Standalone**

Clone anywhere, then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/src/devlease/bin/devlease\" hook",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

Edits to `settings.json` take effect immediately, with no restart — unlike the
plugin route, where hooks load at session start.

The `matcher` above covers the `Bash` tool. If you use a plugin that runs shell
commands through its own MCP tool, add those tool names to the alternation; the
shipped `hooks/hooks.json` does this for context-mode's sandbox tools.

Requires `python3` (standard library only) and `adb` on `PATH`.

## What it gates

| Command | How the target is resolved |
|---|---|
| `adb …` (except `devices`, `version`, `help`) | `-s <serial>` |
| `gradlew install*` / `uninstall*` / `connected*` | `ANDROID_SERIAL` (AGP has no serial flag) |
| `maestro … test` / `record` / `studio` / `hierarchy` | `--device <serial>` |
| `android install` / `run` / `screen` / `layout` | `--device=<serial>` |

Falling back, in order: `-Pdevice=<serial>`, `ANDROID_SERIAL` (env or inline on the
command), then the only attached device. If none of those resolve and more than one
device is attached, the command is refused rather than guessed at — the same mistake
`./gradlew installDebug` makes on its own.

Build-only work is never gated: `assembleDebugAndroidTest` and
`compileDebugAndroidTestKotlin` build the test APK without touching a device, and
`maestro start-device` is what creates an emulator in the first place.

**Always refused, no lease possible:** `adb kill-server`, `start-server`, `root`,
`unroot`, `reboot`, `usb`, `tcpip`, `disconnect`, and `adb -d` / `adb -e`. These
reconfigure the shared adb server or reboot a device out from under whoever holds
it. A human can still run them in their own terminal.

## Using it

Agents are told what to do by the hook itself — a holder is told to release, a
blocked agent is told who holds the device. You need three commands:

```
devlease list              # who holds what
devlease release [serial]  # give back the leases you hold
devlease steal <serial>    # break a stuck lease
```

## Project rules

Some rules only make sense in one repo: a script that must never run locally, a
custom Gradle task that drives a device, a test suite that must stay off physical
hardware. Put those in `.devlease.json`, either in the repo or at `~/.devlease.json`.
Both are read and their rules concatenated.

```json
{
  "denied": ["scripts/reset-device-farm\\.sh"],
  "gated": ["gradlew\\b[^|;&]*?:?e2e:run\\w*Tests\\b"],
  "emulator_only": ["gradlew\\b[^|;&]*?:?e2e:run\\w*Tests\\b"]
}
```

| key | effect |
|---|---|
| `denied` | always refused, no lease possible |
| `gated` | requires a lease |
| `emulator_only` | requires a lease **and** an `emulator-*` serial |

Values are Python regexes matched against the whole command string. A missing or
malformed file costs you those rules and nothing else; the built-in gating still
applies.

## How leases behave

A lease is a directory under `~/.android-devlease/<serial>`, created with `mkdir`,
which is atomic. It is held until the agent runs `devlease release`, and reaped
after 60 minutes idle. Every gated command renews it.

The TTL is deliberately longer than any single command, because nothing renews a
lease while a 20-minute test suite is running. `PostToolUse` cannot help — it fires
when the tool call returns, which for a backgrounded Gradle run is long before the
suite ends. So an abandoned lease is cleared by `devlease steal`, not by a short
timeout.

Each device also records its last holder. When an agent takes a device that someone
else has held since it last did, it is told so, because whatever it installed or set
up there is probably gone. This is what makes both the TTL and `steal` safe: losing a
lease is survivable as long as you find out.

Environment overrides, mostly for testing: `DEVLEASE_DIR`, `DEVLEASE_TTL`,
`DEVLEASE_WAIT`, `DEVLEASE_DEVICES`.

## Known limits

- **Text mentions take leases.** The gate matches command text, so writing a script
  or heredoc that merely contains `adb -s …` takes a lease. This is deliberate: the
  alternative — matching only commands in executable position — misses real
  invocations like `timeout 30 adb …`, and under-blocking is the failure this exists
  to prevent. `devlease release` undoes it.
- **Fails open.** A bug in the hook prints to stderr and allows the command, rather
  than blocking all Android work.
- **Subagents are untested.** Whether a subagent's hook `session_id` matches its
  parent's has not been verified. If it differs, a parent and its subagent will
  block each other on one device.
- **One machine.** Leases are local directories; this does not coordinate across
  hosts or a device farm.

## Tests

```
bash tests/devlease.test.sh
```

No framework, no fixtures — it drives the hook over stdin the way Claude Code does.

## License

MIT
