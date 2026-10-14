# Security Policy

## What the privileged helper is

Fan Control ships two binaries inside `Fan Control.app/Contents/MacOS`:

- `FanControl` — the SwiftUI app. It runs as the logged-in user, samples the
  System Management Controller through the helper, and never writes SMC registers
  itself.
- `smc-helper` — a tiny command-line client with three verbs: `get`, `set <fanId>
  <mode> [<rpm>]`, and `reset`. Writing fan targets requires root, so this binary
  is installed **root-owned and setuid**, at mode **`4755`**.

The app is deliberately **not** sandboxed. It drives fans through a root-privileged
child that ships inside its own bundle, which the App Sandbox forbids; claiming an
app-sandbox entitlement that the OS would honour by breaking the app would be
worse than saying so. Both binaries are signed with the hardened runtime
(`--options runtime`), and the app's entitlements file contains exactly one entry,
`com.apple.security.get-task-allow = false`, so a distributed build cannot be
attached to with a debugger. Hardened runtime is also what stops a `DYLD_*`
environment variable from being used to hijack the setuid helper: library
validation refuses to load an unsigned dylib into a hardened-runtime process, and
`DYLD_*` variables are stripped from setuid children.

## Threat model

**The helper does not authenticate its caller.** Anyone who can execute it gets
root-level SMC writes, including `set <fanId> 1 0`. That is the central fact of
this design, and it is stated here first because everything else is a bound on
it, not a cure for it.

### Why the helper must be world-executable (`4755`)

An earlier revision of this document argued the opposite — that `4700` was
required, because a world-executable setuid root helper is dangerous. **That was
wrong, and it broke the app.** The app spawns the helper **directly with
`Process`, running as the logged-in user**. It never invokes it through `sudo`.
The helper must therefore be executable *by that user*:

| Mode | Outcome |
|---|---|
| `4700` | Root-only execute. The logged-in user gets `EACCES`, `Process.run()` fails, and every thermal poll is lost. |
| `4750 root:wheel` | Also fails — an ordinary user is in group `staff`, not `wheel`. |
| **`4755`** | Setuid root **and** executable by the logged-in user. This is what ships, in both `FanViewModel.authorize()` and `build.sh`'s opt-in `SETUID_HELPER=1` path. |

Worth recording explicitly: the earlier claim that "Apple's own `/usr/bin/smc`
is `4700`" was **factually wrong**, and `/usr/bin/smc` is not even present on the
macOS 27.2 / M5 Max machine these tests ran on. Where the binary does exist it is
`4755` and is invoked *via `sudo`* — precisely because it has to be
world-executable. A restrictive mode and a direct `Process` launch are mutually
exclusive; the app's launch style is what forces the mode, not a security
preference.

### What this costs, stated plainly

Setuid-root **plus** world-executable is a real exposure. Any local user, or any
malware running as that user, can drive your fans — including to zero — through
`smc-helper set <id> 1 <rpm>`. **This design cannot eliminate it.** Describing
the posture as "safe" or "hardened" would be inaccurate. What bounds it today:

- the helper's command surface is small: `get`, `set`, `setall`, `reset`. One verb
  was added to upstream's three — `setall` — but it grants **no new capability**:
  it is the same `writeFan` primitive applied to every fan in one invocation
  (`Helper/main.swift:252-278`), and anyone who can call `setall` could already
  call `set` once per fan. The number of SMC writes an attacker can make is
  unchanged from upstream;
- both binaries carry the hardened runtime, so **library validation** blocks a
  `DYLD_*` injection into the setuid binary;
- `checkAuthorization()` rejects a helper that is **not root-owned**, **not
  setuid**, **not executable** (by owner or by the invoking user), or **writable
  by group or other** — the last being the one that matters most, because a
  setuid-root binary anyone can write is a direct root compromise: the attacker
  replaces the payload and the next invocation runs it as root.

Group/other **execute** access is therefore a requirement, not a defect, and is
deliberately *not* rejected.

### The accepted fix, not yet shipped

The real fix is an **XPC privileged helper (`SMJobBless`)**: the privileged code
moves out of the bundle into a LaunchServices-registered helper that authenticates
the connecting process by audit token, so only the signed GUI app can obtain SMC
writes. That is accepted follow-up work, tracked in
[`docs/FORK_CHANGELOG.md`](docs/FORK_CHANGELOG.md), and it is **not** in the
current tree. Until it ships, treat the helper as root access offered to the
local login session.

### Also in the threat model

- A helper that is *not* root-owned is rejected even if the setuid bit is set,
  because the bit would then escalate to whatever account owns the file.
- The authorize step re-reads the file's ownership and mode after running rather
  than trusting that the shell command succeeded: a hardened runtime, an ACL, or a
  read-only volume can turn the `chmod` into a silent no-op, and the app reports
  failure instead of pretending it is authorized.
- A setuid bit does **not** survive copying the app out of a DMG into
  `/Applications`. The in-app authorize step is therefore the supported path, not
  an optional convenience, and it must be re-run after any reinstall.
- A permissions error on the helper is reported confusingly by the platform:
  `Foundation` surfaces `EACCES` on `exec` as `NSCocoaErrorDomain` **Code=4,
  "the file doesn't exist"**. The app now detects that exact domain/code pair and
  prints an explicit hint about `ls -l`, mode `4755`, and the fact that the helper
  is run directly rather than via `sudo` — because the raw message points at a
  packaging bug that does not exist.

Beyond the helper, the app trusts: the SMC readings it is given (out-of-range and
implausibly large temperature steps are rejected before they can reach the control
law), and its own code signing. Anyone who can modify the signed bundle invalidates
the signature, which macOS checks on launch.

**Not** in the threat model: remote attackers (the helper has no network surface),
physical access to an unlocked login session, or a root-level attacker, who has
strictly more power than the helper offers.

## Known limitation

Force Quit and `kill -9` send `SIGKILL`, which the kernel does not deliver to the
process, so no handler can exist for it. Fan targets written to the SMC are latched
in hardware and survive process exit. If the app is killed that way, the fans stay
at the last written RPM until you relaunch the app and use **Reset All to Auto**,
or restart the Mac. Every other termination path — ⌘Q, the menu-bar **Quit** item,
and `SIGTERM`/`SIGINT`/`SIGHUP` — runs a helper reset before the process exits.
The reset joins the same serial write queue as every other write, so it runs
after any write already in flight, and no new write is accepted once quitting
begins. The app waits at most 12 seconds for the reset and then quits, even if
the reset has not finished. The helper itself is stopped after 8 seconds.

If you are ever unsure what state the fans are in, restart the Mac. It is the one
recovery action that cannot be blocked by a wedged app or helper.

## Reporting a vulnerability

Please report vulnerabilities privately rather than in a public issue. Use the
repository's **Security → Report a vulnerability** tab, which opens a private
GitHub Security Advisory thread with the maintainers. If that tab is unavailable
for this repository, use **Security → Advise** on the GitHub repository this
checkout tracks as `origin`
([ShahzaibAli02/Fanny-MacOs-FanControl](https://github.com/ShahzaibAli02/Fanny-MacOs-FanControl))
and say in the report that the finding is against this fork's tree.

Include the app version, macOS version, Mac model, the exact helper file mode
(`ls -l "Fan Control.app/Contents/MacOS/smc-helper"` — it should show
`-rwsr-xr-x root wheel`, i.e. `4755`), and reproduction steps. There is no fixed
response SLA — this is an unfunded project — so please do not treat silence as a
decision.

Things that are **not** vulnerabilities, by design:

- The helper accepts commands from any process that can execute it, which means
  root-level fan control is available to the local login session. Restricting it
  to the GUI process needs caller authentication — an XPC privileged helper via
  `SMJobBless` — which is accepted follow-up work and a deliberate architectural
  change, not an oversight in the current one. It is documented as a live
  exposure above rather than dismissed.
- Ad-hoc-signed local builds are not distributable and will be rejected by
  Gatekeeper on other Macs. Sign with a Developer ID and notarize
  (`NOTARY_PROFILE=… ./build.sh`) for distribution.
- Manual fan control that outruns Apple's private thermal policy is the user's
  choice; the app is not attempting to reproduce Apple's fan curve.
