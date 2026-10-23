# Permissions and signing

Ponte needs two permissions, and both are bound to something that is easy to break without noticing.

| permission | why | granted |
|---|---|---|
| Microphone | the whole point | asked once, on the first recording |
| Accessibility | to paste the transcript at the cursor with a synthesised ⌘V | asked when auto-paste first runs; the menu has "Repair permissions (clear a stale grant)" |

## The rule

**A TCC grant is bound to the code signature's designated requirement — not to the bundle identifier, not to
the app's path, not to its name.** Every build that satisfies the requirement keeps the grant; every build that
does not gets a fresh prompt, *and* the old entry can stay in System Settings looking enabled while applying to
nothing. A toggle that is on is not evidence that anything is granted.

Ponte's requirement is deliberately team-anchored:

```
identifier "com.ponti.ponte" and anchor apple generic and certificate leaf[subject.OU] = "3QHJ2KN8AL"
```

Any build this team signs satisfies it. That single choice is what makes a grant survive the next rebuild.

## The two ways this has already broken

**Ad-hoc signing.** An ad-hoc signature's requirement is a `cdhash` — a hash of that exact binary — so every
rebuild was a different app as far as TCC was concerned, and the microphone and Accessibility prompts came back
forever. Fixed by signing with a stable identity.

**Alternating identities.** Worse, because it is quieter. `scripts/build-app.sh` preferred the **Apple
Development** certificate while `scripts/make-dmg.sh` signs for distribution with **Developer ID**. Those two
requirements differ (`…100.6.2.12` against `…100.6.2.6`), so every flip between them invalidated the grants made
by the other. The log shows the cliff exactly: dictations report `PASTED OK` at 04:13 and 04:23, then
`COULD NOT PASTE` from 06:37 onwards, which is when the app was rebuilt with the other certificate.

```
# what the app's requirement actually is
codesign -d -r- /Applications/Ponte.app

# fails unless it is team-anchored; explains the ad-hoc and dev-cert failure modes
./scripts/check-signature.sh /Applications/Ponte.app
```

**Sign every build, local and distributed, with the same team identity.** Run `check-signature.sh` after any
change to the signing setup, and never let a development build and a shipped build disagree about who made them.

## Repairing a stale grant

1. Ponte's menu → **Repair permissions (clear a stale grant)**, which resets its own Accessibility entry and
   offers the System Settings pane.
2. Or by hand: `tccutil reset Accessibility com.ponti.ponte`
3. Then toggle it back on **for the build you are actually running** — the entry you are toggling may belong to
   a signature that no longer exists. The minus button removes a stale entry.

The microphone permission behaves the same way, and can be reset with
`tccutil reset Microphone com.ponti.ponte`.

## Entitlements and the hardened runtime

| | |
|---|---|
| entitlement | `com.apple.security.device.audio-input` — required, and *only* this one |
| hardened runtime | on, because notarization requires it |
| sandbox | off — Ponte writes notes to `~/Documents/Ponte` and keeps its models outside its container |

`Resources/Ponte.entitlements` is what `make-dmg.sh` signs with. Adding an entitlement means re-notarizing, and
an entitlement the app does not need is a reason for a notary to look harder at the ones it does.

## Notarization

Unsigned-but-notarized is not a thing, and signed-but-not-notarized is what a buyer sees as *"Apple could not
verify Ponte is free of malware"*. The DMG is signed and verified (Developer ID Application → Developer ID
Certification Authority → Apple Root CA), and notarization is the remaining step. It needs a credential profile
which **the account holder creates, not a script** — the app-specific password should never pass through a
build log or an agent:

```
xcrun notarytool store-credentials ponte-notary --apple-id "<Apple ID>" --team-id 3QHJ2KN8AL --password "<app-specific password>"
./scripts/make-dmg.sh --notarize
```

Notarization does **not** change the designated requirement, so it does not disturb existing TCC grants. If a
future build ever re-signs with a different certificate, though, it will: the requirement is the thing to keep
stable, and the notary ticket is not.
