# Licensing: what it costs the promise

Issue #1. Researched 27 October 2026 against Polar's live documentation and fee page.

## The promise on the site today

> 100% local, forever. Ponte's only network request is checking for its own updates.

That is exactly true of 1.1.0: Sparkle is the only thing that leaves the machine. The first-run model download is
over by the time anyone dictates.

**Charging money breaks this, or does not, depending entirely on how.** There are four honest ways to sell a
notarized Mac app, and they are not variations on a theme — two of them keep the sentence and two of them rewrite it.

## The four options

### 1. Stay free

- App requests: **one** (Sparkle), unchanged.
- Site copy: unchanged.
- Revenue: none. Nothing to build, nothing to run.

### 2. Honour system — buy, get the DMG, no key

Sell through Polar's checkout link; deliver the download as the product. No key, no check, no accounts.

- App requests: **one**, unchanged. The promise survives word for word.
- Cost: Polar Starter **5% + 50¢** (+1.5% on non-US cards), or **4% + 40¢** on the Early Member rate if the org
  predates 27 May 2026. Merchant of record, so no VAT registration, no filings, no EU OSS.
- Risk: a buyer can share the DMG. No device limits, no revocation, no way to tell a customer from a stranger.
- Build: a buy button and a product page. That is all.

### 3. Polar licence key, checked once — then cached

Polar issues a key (`PONTE_…`) with activation limits, revocation, expiry and a customer portal where the buyer can
deactivate a device or rotate an exposed key.

- Verification path: `POST https://api.polar.sh/v1/customer-portal/license-keys/validate` with the key and the
  organisation id. Polar's docs recommend calling it "for each session"; **that recommendation is not binding**, and
  the app decides.
- Proposed policy: **validate once, at activation, and store the result**. Re-validate only when the user presses
  "Check licence", or after 30 days. A revoked key is then caught within a month, not within a minute.
- App requests: **two** on the day of purchase, then nothing. The promise becomes: *"Two requests: its update check,
  and one licence activation when you buy. Then nothing."*
- Cost: as option 2. Fee is per transaction, so one sale is one fee whatever the price.
- Build: a licence field in the window, a Keychain entry, and an offline-grace rule: if the app cannot reach Polar it
  keeps working, because a paying customer on a plane is not a pirate.
- This is the only option that can revoke, count devices, and give a refund path a meaningful end.

### 4. Self-signed licence file — zero calls

A tiny worker mints an Ed25519-signed licence at purchase; the app verifies the signature locally and never speaks to
anything.

- App requests: **one**, unchanged.
- Cost: as option 2, plus a worker to run and a key to keep.
- Risk: no device limits, no revocation — a leaked file works forever, exactly like option 2, but with more moving
  parts. The signature stops someone *typing* a fake key; it does not stop sharing.

## Recommendation

**Option 3, with the once-and-cached policy.** Not because it is the cheapest to build — option 2 is — but because
it is the only one that can revoke a key, bound the number of devices, and tell a customer from a stranger, and those
are the things that make a paid product defensible when someone posts the DMG. The cost is one request on the day of
purchase, which is a sentence the site can say out loud without flinching.

If the "one request" claim matters more than any of that — and it is the pitch — then **option 2** is the honest
choice, and the app needs no licensing code at all.

**Option 1 remains correct until there is something to sell.** Nothing in this document needs building this week.

## What each option costs the README

The README's `## Updates` table says what is sent and what is not. Each option changes it as follows:

| option | README / site wording |
|---|---|
| 1 | unchanged: *its update check, and nothing else* |
| 2 | unchanged: *its update check, and nothing else* |
| 3 | *its update check; and a one-time licence activation when you buy one* |
| 4 | unchanged: *its update check, and nothing else* |

Nothing in any option sends audio, transcripts, vocabulary or usage. That part of the promise is not for sale.

## The money, concretely

Polar charges a percentage plus a fixed fee per transaction, whichever currency, and is the merchant of record — so
VAT on a UK sale and EU VAT are collected and remitted by them, not by whoever owns Ponte.

Assumptions: a £19 price **including** 20% VAT (so £15.83 is the seller's before fees), £1 = $1.25, and Polar's fee
applied to the tax-inclusive total, which is how their own worked example computes it.

| plan | card | fee | VAT | **you keep** |
|---|---|---|---|---|
| Early Member 4% + 40¢ | UK | £1.08 | £3.17 | **£14.75** (78%) |
| Early Member 4% + 40¢ | non-UK (+1.5%) | £1.37 | £3.17 | **£14.47** (76%) |
| Starter 5% + 50¢ | non-UK (+1.5%) | £1.64 | £3.17 | **£14.20** (75%) |

No monthly fee on either plan. At roughly $1,379/month in sales the Pro plan (3.8% + 40¢, $20/month) becomes
cheaper; that is not a problem worth solving now. Disputes cost $15 each, and refunds do not return the original
transaction fee — both worth knowing before pricing low.

The fixed 40–50¢ is why a £9 price is a bad idea: on Starter it is 5.6% of the sale before the percentage even
applies.

## If option 3 is chosen, what gets built

1. `Licence` in the app: key entry in the window's General pane, stored in the Keychain, validated on activation.
2. A `validate` call with the organisation id, a 10-second timeout, and one retry — then a cached result and a clear
   "couldn't reach Polar, Ponte still works" state.
3. A licence state the rest of the app can read (licensed / trial / unlicensed), and **one** place that enforces it —
   never scattered through the paste path.
4. A documented re-check policy: on demand, and every 30 days.
5. Tests: no key means the app works as it does today; a validation failure is not a failed dictation; an unreachable
   server never blocks a paste.
6. README and site copy updated to the wording in the table above.

## Open questions for Charles

- Sell at all, and if so which option.
- One-time price or "pay what you want" (Polar supports it, and it fits the honour-system option rather than the key).
- Whether an unlicensed user is limited (a trial of N dictations, a nag, nothing at all) or the app simply works and
  asks.
