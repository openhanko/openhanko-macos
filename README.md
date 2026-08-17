# openhanko-macos

The macOS side of [OpenHanko](https://openhanko.io): a CryptoTokenKit token
driver that replaces Apple's built-in `pivtoken`, the app that carries it, and
the PAM module that lets `sudo` use the device.

The firmware lives in `openhanko-firmware`; the site in `openhanko-web`.

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


## Building

```
./build.sh              build and sign into build/
./build.sh install      also copy to /Applications and register the extension
./package.sh 0.1.0      signed, notarised, stapled DMG for release
```

`package.sh` needs a notarytool profile: create one once with
`xcrun notarytool store-credentials openhanko-notary --apple-id … --team-id …
--password <app-specific>`, or point `NOTARY_PROFILE` at an existing one.

## Status

**Working end to end, with hardware pinpad PIN entry.** `sudo` authenticates
against the device with a single button press, and the PIN is verified by
pressing the button rather than by the digits typed.

```
sign 32 bytes with PIV algorithm 11
card requires authentication; asking CryptoTokenKit for it
beginAuth for operation 2
reader supports secure PIN entry; deferring to the pinpad
secure PIN verification: success=true sw=9000
signature 72 bytes
```

On the wire, 483 ms from the pinpad request to a completed signature:

```
34137  APDU 00 87 11 9A  → 6982    first attempt, refused
34143  CCID 69 Secure               macOS delegates PIN entry to the reader
34147  EVENT BUTTON                 answered by the press
34626  APDU 00 87 11 9A  → 9000    signed
```

Be clear about what this does and does not fix. The PIN **prompt** still
appears, because it comes from `pam_smartcard.so`, upstream of CryptoTokenKit —
pinpad only governs the CTK-to-card leg. The device still types `000000` to
satisfy that prompt, so the "typed into whatever has focus" problem is
unchanged. What is gained is that the typed digits no longer authenticate
anything: the card only verifies when someone physically presses the button.

## Build

```sh
./build.sh            # build and sign into build/
./build.sh install    # also copy to /Applications and register
```

Assembled by hand rather than with an `.xcodeproj`. An app extension bundle is
just an `Info.plist` and a Mach-O linked with `-e _NSExtensionMain`, which is
easier to read and to keep in a repo than several thousand lines of `pbxproj`.

Signing needs a **Developer ID Application** identity; `build.sh` picks the
first one in the keychain, or set `CODESIGN_IDENTITY`. Ad-hoc signing is not
enough.

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
lsregister -f /Applications/SmartCardTokenApp.app
open /Applications/SmartCardTokenApp.app
```

Until then `pluginkit -m -p com.apple.ctk-tokens` simply does not list it, with
no error anywhere. `pluginkit -m -A -D -vvv | grep -i smartcardtoken` shows
records that the filtered listing hides, which is the quickest way to tell
"not registered" from "registered but not matching".

## Design

| file | role |
| --- | --- |
| `Sources/Token/TokenDriver.swift` | driver, token, session — the whole implementation |
| `Sources/App/main.swift` | container app; exists only so the extension can be registered |
| `Resources/Info-ext.plist` | `com.apple.ctk.*` keys that make it a token driver |
| `Resources/token.entitlements` | sandbox + smart-card |

`Info-ext.plist` uses `com.apple.ctk.driver-class`, **not**
`NSExtensionPrincipalClass`, and the value is the Swift-mangled
`<Module>.<Class>` — hence `-module-name SmartCardToken` in the build script.

The driver claims the PIV AID `A000000308000010000100`, which Apple's `pivtoken`
also claims. Which driver wins is the next thing to establish; if `pivtoken`
takes precedence, the fallback is to give the applet a private AID so only this
driver matches.

## Debugging an extension you cannot attach to

`Logger.info` is **memory-only**: `log show` cannot retrieve it after the fact,
so early diagnosis here was entirely blind. Milestones now go through `note()`,
which logs at error level and therefore persists:

```sh
log show --last 5m --predicate 'subsystem == "dev.smartcard.token"' --style compact
```

Interpolated values need `privacy: .public` or they appear as `<private>`.

To watch live instead, which also catches CryptoTokenKit's own chatter:

```sh
log stream --predicate 'process == "SmartCardToken"' --level debug --style compact
```

That is how the decisive observation was made — CryptoTokenKit logging
`'session:objectID:operation:data:algorithms:parameters:reply:'` and
`sync req: 87 119a` with no preceding `beginAuth`, which is what showed
authentication was being skipped rather than failing.

Useful state checks, in rough order of trustworthiness:

| question | command |
| --- | --- |
| is the driver registered? | `system_profiler SPSmartCardsDataType` (look under SmartCard Drivers) |
| which driver owns the card? | `sc_auth identities` — the `SmartCard:` line names the token |
| is the extension actually running? | `pgrep -fl SmartCardToken.appex` |
| did it crash? | `ls ~/Library/Logs/DiagnosticReports \| grep -i smartcard` |

`pluginkit -m -p com.apple.ctk-tokens` is the least reliable of these: it has
listed nothing while `system_profiler` showed the driver present and working.

**Do not `pkill` the extension or `killall ctkd` to force a reload.** It leaves
ctkd serving a cached token identity for an extension it will no longer launch —
`sc_auth` keeps reporting the token, no APDUs reach the card, and nothing is
logged, which looks exactly like a code bug and is not one. Recovering takes a
full reset: remove the app, `killall ctkd pkd`, reinstall, `lsregister -f`,
launch the app, then re-insert the card.

## The two non-obvious bugs

Both cost hours, and neither produces a useful error.

### beginAuth is never called until the operation asks for it

Setting `TKTokenKeychainKey.constraints` is necessary but **not sufficient**.
The constraint only declares that authentication is *possible*. CryptoTokenKit
calls `sign` first regardless, and only calls `beginAuthForOperation` once that
operation fails with **`TKErrorCodeAuthenticationNeeded`** specifically. Return
any other error — as this driver did for a long while, propagating the card's
`6982` as a generic failure — and the system gives up without ever asking,
which looks exactly like the constraint being ignored.

```swift
} catch CardError.status(0x6982) {
    throw TKError(.authenticationNeeded)   // the only error CTK acts on
}
```

OpenSCToken does the same thing, mapping `SC_ERROR_SECURITY_STATUS_NOT_SATISFIED`
onto `TKErrorCodeAuthenticationNeeded`.

### Answering a pinpad request too quickly drops the answer

The firmware used to send a CCID time extension the instant
`PC_to_RDR_Secure` arrived. That is fine when a human takes seconds to press the
button, but once one press was made to satisfy both the PIN prompt and the
pinpad request, the real answer went out ~4 ms later — while the first bulk IN
transfer was still in flight. `usbd_edpt_xfer` fails in that case, the answer is
silently dropped, and the host waits until it times out.

Fixed by not sending that initial extension at all; the periodic tick sends the
first one a second later, by which time the endpoint is free.

## Pinpad works — but `sudo` does not use it

This took three experiments to get right, and the obvious conclusion was wrong.

Signing through the Security framework with **no PAM in the path** (see
`sign.swift` in the commit history, or any app doing client-certificate auth):

```
9663    APDU 00 87 11 9A  → 6982     sign refused
9671    APDU 00 A4 04 00  → 6a82     beginAuth ran
129680  CCID 69 Secure                pinpad request — no dialog shown
132171  EVENT BUTTON                  the press
132648  APDU 00 87 11 9A  → 9000     signed
```

**No PIN dialog, nothing typed, authenticated by the button alone.** That is
what a pinpad reader is for, and CryptoTokenKit does it correctly.

`sudo` behaves differently, and the difference is PAM, not CryptoTokenKit:

| path | who collects the PIN | pinpad used? | dialog? |
| --- | --- | --- | --- |
| `sudo` | `pam_smartcard`, before CTK is consulted | no | yes, and the PIN is typed |
| Security framework / SecKey | CryptoTokenKit | **yes** | **none** |

So `pam_smartcard` prompts on the TTY and hands the PIN to the token as a
pre-filled value, which is why the token never gets to ask the reader. Anything
going through `SecKeyCreateSignature` — browser client certificates, SSH via
CTK, code signing — gets the pinpad path with no typing at all.

### Driving the reader must be explicit

Handing back a `TKTokenSmartCardPINAuthOperation` with `APDUTemplate` set is
what Apple's header recommends, and it does not work: measured on macOS 26.6,
the template is ignored, no `PC_to_RDR_Secure` is sent, and `PIN` arrives
populated. Calling `userInteractionForSecurePINVerification` from the auth
operation's `finish()` is what actually reaches the reader.

### The device needs a way to say "press me"

With pinpad there is no on-screen prompt at all, so a device with no indicator
leaves the user with nothing to react to. The RP2040 build drives a WS2812 on
GP16 that breathes only while a pinpad request is outstanding:

```
33313  CCID 69 Secure           pinpad request — LED starts breathing
39123  EVENT BUTTON             pressed 5.8 s later
39589  APDU 00 87 11 9A → 9000  signed
```

No dialog, nothing typed, and no instructions needed — the light is the prompt.

## Authenticating a user without a PIN

`tools/pam/smartcard-auth.c` authenticates a user by proving possession of a
smart-card key paired to them — no PIN, just a press:

```
$ ./tools/pam/smartcard-auth
vden has 3 paired identity(ies)
  9033F36E...: paired — challenging
  waiting for the reader...
  signature verified — vden authenticated
```

```
517141  CCID 69 Secure               pinpad request, LED breathing
526268  EVENT BUTTON                 the press
526735  APDU 00 87 11 9A → 9000     signed and verified
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
authentication costs exactly one press.

### The PAM module

`tools/pam/` builds this into a PAM module. Installed, `sudo` authenticates by
pressing the button — **no PIN prompt at all**:

```sh
./tools/pam/build.sh
sudo ./tools/pam/install.sh     # auth sufficient, in /etc/pam.d/sudo_local
sudo ./tools/pam/uninstall.sh   # to undo
```

It cannot lock you out. `sufficient` means anything other than success falls
through to the existing password stack, and the module returns
`PAM_AUTHINFO_UNAVAIL` for every condition except "a paired card was present and
failed its challenge".

**It must be fork+exec, not fork.** The first version forked and called
OpenDirectory in the child, which crashes by design:

```
objc[2603]: +[ODSession initialize] may have been in progress in another thread
when fork() was called. ... Crashing instead.
```

OpenDirectory and Security are Objective-C underneath, and the runtime refuses
to run after a fork without exec. The module therefore forks, drops to the
invoking user, and execs `/usr/local/libexec/smartcard-auth-helper`. Dropping
privileges is required anyway — token keys live in the user's CryptoTokenKit
session, not root's — and the separate process means a crash cannot take `sudo`
with it. That was proven the hard way: the child died and `sudo` still worked.

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
module there would add a button press *after* the PIN rather than replacing it.

### GUI prompts cannot be covered at all on macOS 26

An authorization plugin was built (`tools/authplugin/`) and is the right tool in
principle: mechanisms placed ahead of `builtin:authenticate` can grant
authorization before any UI appears. It was installed into the shared
`authenticate` right and **was never invoked**, because nothing reaches that
right any more.

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
  waiting for a button press before falling through.
- A correct password came back "incorrect"; Touch ID was rejected too. Recovery
  required a reboot, because the initial login window uses
  `system.login.console`, which the plugin does not touch.

The design returned `Undefined` rather than `Deny` specifically so failures would
fall through to the password — and that part worked. The mistake was latency, not
the return value. **Any mechanism in an authentication path must return
promptly, always**, and a mechanism that waits on a human cannot live in a right
the lock screen depends on.

**Net position:** `sudo` and anything going through `SecKeyCreateSignature` can
be authenticated by presence. GUI authorization prompts cannot, by construction.

## Open questions

- Does smart-card **login** work with a third-party token? `TKTokenKeychainKey`
  has `isSuitableForLogin`, which is set here, but it is untested.
- Can the driver drop the HID PIN typing entirely? The prompt comes from PAM,
  so probably not without a host-side helper.
