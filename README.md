# openhanko-macos

The macOS side of [OpenHanko](https://openhanko.io): a CryptoTokenKit token
driver that replaces Apple's built-in `pivtoken`, the app that carries it and
gives the device an interface, and the PAM module that lets `sudo` use it.

The firmware lives in `openhanko-firmware`; the site in `openhanko-web`.

## The app

It has to exist — `pluginkit` only registers an extension that lives inside an
application bundle — and it is also where the device gets an interface.

Everything the device knows about itself is on its serial console, reachable
only from a terminal. The states that matter most are the ones nobody would
otherwise see: a sensor that has been swapped shows red on the ring and nothing
else, adding a finger is a gesture performed blind, and the idle light is a
device setting with nowhere to set it from.

| | |
| --- | --- |
| **Status** | What is wrong, in words, and the one action that fixes it |
| **Fingerprints** | Enrolment, narrated live from the device's own events |
| **Settings** | The idle light, stored on the device |
| **Diagnostics** | `TRACE`, sensor identity, and a one-click paste for support |
| **Update** | Installs a signed image by copying it to the bootloader volume |

`Sources/App/DeviceConsole.swift` is the console client — the same line protocol
`provision.py` speaks. `DeviceAgent` owns exactly one connection to it, because
five panes asking the device things at once produces replies to the wrong
questions.

**The app and `provision.py` cannot both hold the device.** macOS does not lock
`cu.` devices, so two clients do not fail — they interleave, and a command
answered by somebody else's `OK` is indistinguishable from the firmware
misbehaving. The app claims the port with `TIOCEXCL`, which turns that into a
plain "already in use" from whichever asks second. Closing the app's window
quits it and releases the port.

## Why a driver at all

The device works on an untouched Mac without any of this — it answers the
standard PIV AID and Apple's own `pivtoken` binds to it. This driver is the
optional upgrade, and it exists for one reason:

**PIN entry.** Apple's `pivtoken` always collects the PIN in a dialog, and the
device then types it over HID. A custom driver can hand CryptoTokenKit an
`APDUTemplate`, which per Apple's header "allows using hardware PINPad for
secure PIN entry (provided that the reader has one)". The firmware implements
`PC_to_RDR_Secure` and declares `bPINSupport = 0x01`, which Apple's driver
ignores entirely — so with this one installed the touch *is* the PIN entry: no
field, no keystrokes, no dialog.

## Status

**Working end to end, with hardware pinpad PIN entry.** `sudo` authenticates
against the device with a single fingerprint, and the PIN is verified by that
match rather than by the digits typed.

On the wire that is four exchanges: a signature refused with `6982`, the
`PC_to_RDR_Secure` macOS sends in response, the fingerprint, and the signature.

Be clear about what this does and does not fix. Pinpad governs the
CryptoTokenKit-to-card leg only. Anything that collects a PIN *before* CTK is
consulted, or that puts up its own PIN field, never reaches it — see
[what pinpad reaches](#what-pinpad-reaches) below.

## Build

```sh
./build.sh            # build and sign into build/
./build.sh install    # also copy to /Applications and register the extension
./package.sh 0.1.0    # signed, notarised, stapled DMG for release
```

Assembled by hand rather than with an `.xcodeproj`. An app extension bundle is
just an `Info.plist` and a Mach-O linked with `-e _NSExtensionMain`, which is
easier to read and to keep in a repo than several thousand lines of `pbxproj`.

Signing needs a **Developer ID Application** identity; `build.sh` picks the first
one in the keychain, or set `CODESIGN_IDENTITY`. Ad-hoc signing is not enough.
`package.sh` additionally needs a notarytool profile: create one once with `xcrun
notarytool store-credentials openhanko-notary --apple-id … --team-id … --password
<app-specific>`, or point `NOTARY_PROFILE` at an existing one.

## Two things that will waste your afternoon

**Extensions must be sandboxed.** Without
`com.apple.security.app-sandbox`, `pkd` silently refuses to register the
extension. The only evidence is one line in its log:

```
$ log show --last 5m --predicate 'process == "pkd"' --info --debug | grep rejecting
rejecting; Ignoring mis-configured plugin at [....appex]: plug-ins must be sandboxed
```

`com.apple.security.smartcard` is needed alongside it, or the extension
registers but every APDU fails. Both live in `Resources/token.entitlements`,
and they are exactly what the shipping EstEID token uses.

**Registration is not automatic.** Copying the app into `/Applications` is not
enough, and neither is `pluginkit -a`. What actually works:

```sh
lsregister -f /Applications/OpenHanko.app
open /Applications/OpenHanko.app
```

Until then `pluginkit -m -p com.apple.ctk-tokens` simply does not list it, with
no error anywhere. `pluginkit -m -A -D -vvv | grep -i openhanko` shows
records that the filtered listing hides, which is the quickest way to tell
"not registered" from "registered but not matching".

## Design

| file | role |
| --- | --- |
| `Sources/Token/TokenDriver.swift` | driver, token, session — the whole extension |
| `Sources/App/DeviceConsole.swift` | serial client for the device's line protocol |
| `Sources/App/DeviceAgent.swift` | sole owner of that connection; polling and event listening |
| `Sources/App/Pane*.swift` | one file per pane, over the shared chrome in `UI.swift` |
| `Resources/Info-ext.plist` | `com.apple.ctk.*` keys that make the extension a token driver |
| `Resources/token.entitlements` | sandbox + smart-card |

`Info-ext.plist` uses `com.apple.ctk.driver-class`, **not**
`NSExtensionPrincipalClass`, and the value is the Swift-mangled
`<Module>.<Class>` — hence `-module-name OpenHankoToken` in the build script.

**The driver claims the private AID `F0534D43415244`, not the standard PIV one.**
Apple's `pivtoken` claims the standard AID, macOS binds exactly one driver per
card at insertion, and claiming the same AID means racing it. A private AID makes
the match unambiguous — and doubles as the probe the firmware uses to work out
that this driver is installed at all, since nothing else knows to ask for it.

## Debugging an extension you cannot attach to

`Logger.info` is **memory-only**: `log show` cannot retrieve it after the fact,
so early diagnosis here was entirely blind. Milestones now go through `note()`,
which logs at error level and therefore persists:

```sh
log show --last 5m --predicate 'subsystem == "io.openhanko.app.token"' --style compact
```

Interpolated values need `privacy: .public` or they appear as `<private>`.

To watch live instead, which also catches CryptoTokenKit's own chatter:

```sh
log stream --predicate 'process == "OpenHankoToken"' --level debug --style compact
```

CryptoTokenKit's own lines are the ones worth reading: `sync req: 87 119a` with
no preceding `beginAuth` means authentication is being skipped rather than
failing.

Useful state checks, in rough order of trustworthiness:

| question | command |
| --- | --- |
| is the driver registered? | `system_profiler SPSmartCardsDataType` (look under SmartCard Drivers) |
| which driver owns the card? | `sc_auth identities` — the `SmartCard:` line names the token |
| is the extension actually running? | `pgrep -fl OpenHankoToken.appex` |
| did it crash? | `ls ~/Library/Logs/DiagnosticReports \| grep -i openhanko` |

`pluginkit -m -p com.apple.ctk-tokens` is the least reliable of these: it has
listed nothing while `system_profiler` showed the driver present and working.

**Do not `pkill` the extension or `killall ctkd` to force a reload.** It leaves
ctkd serving a cached token identity for an extension it will no longer launch —
`sc_auth` keeps reporting the token, no APDUs reach the card, and nothing is
logged, which looks exactly like a code bug and is not one. Recovering takes a
full reset: remove the app, `killall ctkd pkd`, reinstall, `lsregister -f`,
launch the app, then re-insert the card.

## The two non-obvious bugs

Neither produces a useful error.

### beginAuth is never called until the operation asks for it

Setting `TKTokenKeychainKey.constraints` is necessary but **not sufficient**.
The constraint only declares that authentication is *possible*. CryptoTokenKit
calls `sign` first regardless, and only calls `beginAuthForOperation` once that
operation fails with **`TKErrorCodeAuthenticationNeeded`** specifically. Return
any other error — propagating the card's `6982` as a generic failure, say — and
the system gives up without ever asking, which looks exactly like the constraint
being ignored.

```swift
} catch CardError.status(0x6982) {
    throw TKError(.authenticationNeeded)   // the only error CTK acts on
}
```

OpenSCToken does the same thing, mapping `SC_ERROR_SECURITY_STATUS_NOT_SATISFIED`
onto `TKErrorCodeAuthenticationNeeded`.

### Answering a pinpad request too quickly drops the answer

A CCID time extension sent the instant `PC_to_RDR_Secure` arrives is fine when a
human takes seconds to answer. It is not fine when one act of presence satisfies
both the PIN prompt and the pinpad request: the real answer goes out ~4 ms later,
while the first bulk IN transfer is still in flight. `usbd_edpt_xfer` fails, the
answer is silently dropped, and the host waits until it times out.

The firmware therefore sends no initial extension; the periodic tick sends the
first one a second later, by which time the endpoint is free.

## Pinpad, and how far it reaches

Signing through the Security framework with **no PAM in the path** — any app
doing client-certificate authentication — the card is refused with `6982`, `beginAuth` runs — visible as a failed SELECT
of the standard AID, `6a82` — a pinpad request arrives with no dialog on screen,
and the signature completes on a fingerprint.

**No PIN dialog, nothing typed, authenticated by presence alone.** That is
what a pinpad reader is for, and CryptoTokenKit does it correctly.

### What pinpad reaches

Pinpad only governs the leg between CryptoTokenKit and the card. Whether you see
a PIN field depends on who collects it first:

| path | who collects the PIN | pinpad used? | PIN field? |
| --- | --- | --- | --- |
| `sudo`, with `tools/pam` installed | CryptoTokenKit | **yes** | **none** |
| `sudo`, stock | `pam_smartcard`, before CTK is consulted | no | yes, on the TTY |
| Security framework / SecKey | CryptoTokenKit | **yes** | **none** |
| apps with their own PIN UI, e.g. Chrome | the application | no | yes |

`sudo` is seamless once `tools/pam` is installed, and that is the reason the
module exists: `pam_smartcard.so` does not link CryptoTokenKit and has no pinpad
path, so it prompts on the TTY and hands the token a pre-filled PIN. Our module
runs ahead of it as `sufficient` and authenticates through CTK instead, which
puts the device back in charge: a `sudo` on that path carries `CCID 69 Secure`,
presence and the signature, with no `VERIFY` in it at all.

Applications that present their own PIN field are the remaining gap. Chrome's
password manager unlocks correctly but still shows a modal, and the device types
six random digits into it. Nothing in the token driver can change that: the
application never asks CryptoTokenKit to authenticate, so the reader is never
consulted.

### Driving the reader must be explicit

Handing back a `TKTokenSmartCardPINAuthOperation` with `APDUTemplate` set is
what Apple's header recommends, and it does not work: measured on macOS 26.6,
the template is ignored, no `PC_to_RDR_Secure` is sent, and `PIN` arrives
populated. Calling `userInteractionForSecurePINVerification` from the auth
operation's `finish()` is what actually reaches the reader.

### The device needs a way to say "touch me"

With pinpad there is no on-screen prompt at all, so a device with no indicator
leaves the user with nothing to react to. The firmware flashes the ring blue
while a pinpad request is outstanding, and that is the only thing telling the
user anything is waiting: no dialog, nothing typed, no instructions — the light
is the prompt. It is the fingerprint module's own ring, which is also the surface
being touched, so the invitation and the control are the same object.

## Authenticating a user without a PIN

`tools/pam/smartcard-auth.c` authenticates a user by proving possession of a
smart-card key paired to them — no PIN, just a finger:

```
$ ./tools/pam/smartcard-auth
vden has 3 paired identity(ies)
  9033F36E...: paired — challenging
  waiting for the reader...
  signature verified — vden authenticated
```

It exists because `pam_smartcard.so` cannot do this. That module links only
Security and OpenDirectory — **not CryptoTokenKit** — and contains the literal
string `"Enter PIN for '%s': "`. It collects the PIN itself and has no pinpad
code path at all, which is why `sudo`, the login window and SecurityAgent-
mediated prompts all type a PIN while `SecKeyCreateSignature` does not.

The check is a challenge-response:

1. read the user's `;tokenidentity;<hash>` entries from `AuthenticationAuthority`
2. find a token key whose `kSecAttrApplicationLabel` (the SHA-1 of its public
   key, which is what `sc_auth` pairs against) matches one of them
3. sign a fresh 32-byte random challenge — this is what reaches the reader
4. verify the signature with the corresponding public key

Step 2 stops another card authenticating as you; step 3 stops a replay; and
`piv.c` clears the PIN-verified window after every signature, so each
authentication costs exactly one fingerprint.

### The PAM module

`tools/pam/` builds this into a PAM module. Installed, `sudo` authenticates by
touching the sensor — **no PIN prompt at all**:

```sh
./tools/pam/build.sh
sudo ./tools/pam/install.sh     # auth sufficient, in /etc/pam.d/sudo_local
sudo ./tools/pam/uninstall.sh   # to undo
```

It cannot lock you out. `sufficient` means anything other than success falls
through to the existing password stack, and the module returns
`PAM_AUTHINFO_UNAVAIL` for every condition except "a paired card was present and
failed its challenge".

**It must be fork+exec, not fork.** Calling OpenDirectory in a forked child
crashes by design:

```
objc[2603]: +[ODSession initialize] may have been in progress in another thread
when fork() was called. ... Crashing instead.
```

OpenDirectory and Security are Objective-C underneath, and the runtime refuses
to run after a fork without exec. The module therefore forks, drops to the
invoking user, and execs `/usr/local/libexec/smartcard-auth-helper`. Dropping
privileges is required anyway — token keys live in the user's CryptoTokenKit
session, not root's — and the separate process means a crash in the helper
cannot take `sudo` with it.

### What it does not cover

GUI authorization prompts — Chrome's password manager, unlocking Settings, the
lock screen — still ask for a PIN, and a PAM module cannot change that. Those
stacks use `use_first_pass`:

```
# /etc/pam.d/authorization
auth  required  pam_opendirectory.so use_first_pass nullok
```

which means **SecurityAgent collects the credential before the PAM stack runs**.
For `sudo`, PAM did the prompting, so replacing the module removed the prompt.
For GUI authorization the prompt happens upstream of PAM entirely, so adding a
module there would add a touch *after* the PIN rather than replacing it.

### GUI prompts cannot be covered at all on macOS 26

An authorization plugin (`tools/authplugin/`) is the right tool in principle:
mechanisms placed ahead of `builtin:authenticate` can grant authorization before
any UI appears. Installed into the shared `authenticate` right it is **never
invoked**, because nothing reaches that right any more.

Measured on macOS 26.6, unlocking Privacy & Security and Users & Groups:

```
processes creating LAContexts:
   SecurityPrivacyExtension: 46     Privacy & Security pane
   UsersGroups: 12                  Users & Groups pane

authorizationhost mechanisms invoked: 0
```

Chrome's password manager behaves identically — `Creating LAContext`, then
`coreauthd`, with SecurityAgent only borrowed to draw the UI.

So GUI authentication has moved to **LocalAuthentication**, and LocalAuthentication
has no third-party extension point: Apple decides what `LAContext` accepts
(password, Touch ID, Watch, smart-card PIN) and there is no API to add
"presence on this reader" to that list. The authorization database is legacy for
these flows.

**Do not install it.** `tools/authplugin/install.sh` now refuses to run. Beyond
being useless on macOS 26, installing it **locked a machine out of its lock
screen**:

- The mechanism sat in the *shared* `authenticate` right, which the lock screen
  evaluates.
- Every unlock attempt ran it first, where it blocked for up to 20 seconds
  waiting for the device to signal presence before falling through.
- A correct password came back "incorrect"; Touch ID was rejected too. Recovery
  required a reboot, because the initial login window uses
  `system.login.console`, which the plugin does not touch.

Returning `Undefined` rather than `Deny` is not enough to make this safe. The
fall-through to the password worked exactly as designed, and the machine was
locked out anyway, because the failure was latency. **Any mechanism in an
authentication path must return promptly, always** — one that waits on a human
cannot live in a right the lock screen depends on.

**Net position:** `sudo` and anything going through `SecKeyCreateSignature` can
be authenticated by presence. GUI authorization prompts cannot, by construction.

## Open questions

- How much of the keychain does slot 9D actually gate? A screen unlock produces
  one ECDH on 9D, but re-unlocking a login keychain that has since auto-locked
  produces no card traffic at all — macOS goes straight to the password there.
  Which operations take the card route is not mapped.
