# Research: selling Ponte through Polar

**Linear: WYA-219** · https://linear.app/wyattbose/issue/WYA-219

Researched 27 October 2026. Nothing here is built; Ponte 1.1.0 stays free and published until the decision on this
ticket is made.

## Why

Ponte 1.1.0 is published and free: notarized DMG, live Sparkle feed, site says one network request — its update check. Selling it is a separate decision that has not been made (GitHub `charlesponti/ponte#1`, analysis in `docs/licensing.md`), and this ticket is the research that decision needs: **should Ponte be sold through Polar, and if so exactly how.**

Polar is the leading candidate because it is a merchant of record — VAT on UK and EU sales is collected and remitted by them, so a sole trader needs no VAT registration, no OSS filings, and no accountant.

## What is already established (researched 27 October 2026, from Polar's live docs)

**Fees** (no monthly fee on either plan; fee applies to the tax-inclusive total):

| plan | per transaction | notes |
|---|---|---|
| Starter | 5% + 50¢ | default for orgs created after 27 May 2026 |
| Early Member | 4% + 40¢ | orgs created before that date, kept indefinitely |
| Pro / Growth / Scale | 3.8% + 40¢ / 3.6% + 35¢ / 3.4% + 30¢ | $20/$100/$400 a month; Pro breaks even ~$1,379/month of sales |

Plus **+1.5% on non-US cards**, **$15 per dispute**, and refunds do not return the original transaction fee.

Worked example at a £19 price including 20% VAT, Early Member rate, non-UK card: fee £1.37, VAT £3.17, seller keeps **£14.47 (76%)**. On Starter: £14.20 (75%).

**Licence keys** (Polar benefit type): brandable prefix (`PONTE_…`), optional expiry, automatic revocation when a subscription ends, **activation limits** (devices), custom validation conditions, usage quotas, key rotation by merchant or customer.

**Validation** is a server call: `POST https://api.polar.sh/v1/customer-portal/license-keys/validate` with `key` + `organization_id` (+ `activation_id` when activation limits are on). Activation first via `POST /v1/customer-portal/license-keys/activate`. Polar recommends validating "for each session"; that is a recommendation, not a constraint — once-at-activation-then-cached is feasible.

**Checkout links** are long-lived URLs configured in the dashboard — no backend needed, which matters because the Ponte site is static GitHub Pages.

**Customer portal** lets a buyer view/rotate their key and deactivate devices without the seller building anything.

## The constraint that decides the shape

The site currently says, and it is true of 1.1.0:

> Ponte's only network request is checking for its own updates.

A Polar licence key requires one call to validate. So the choice is between:

- **Honour system** — sell, deliver the DMG, no key. Keeps the sentence word for word; no revocation, no device limits, no way to tell customer from stranger.
- **Licence key, validated once at activation, then cached** — one request on the day of purchase. Sentence becomes *"its update check, and a one-time licence activation when you buy"*. Gains revocation, device limits, rotation, customer portal.
- **Self-signed licence file** minted by a small worker — keeps the sentence, needs infrastructure, still no revocation.

## What this ticket must answer

**Tax and money**
1. Confirm Ponte qualifies: digital product, UK sole trader, VAT handled by Polar as MoR. What does the seller still have to do — register, file, keep records, and does the £90k UK VAT threshold apply at all when an MoR sells?
2. Payouts to a UK bank account: currency, timing, minimums, fees, and what identity/KYC Polar requires from the seller.
3. Do the fee tiers above still hold, and does an existing org get Early Member?

**Product and delivery**
4. How is the app actually delivered? Polar file download benefit vs a private GitHub release vs the existing public DMG with a licence gate. Which keeps the notarized-DMG distribution we already have?
5. Licence key configuration: activation limit (how many Macs per buyer?), expiry or none, custom conditions (e.g. major version so 2.0 can be a paid upgrade).
6. What happens on validation failure, and what the app should do offline. Proposed rule: a paying customer with no network keeps working; a revoked key is caught within 30 days.
7. Refunds and disputes: who decides, what Polar does automatically, and how a revoked key interacts with a refunded order.

**Marketing and pricing**
8. One-time price vs pay-what-you-want (Polar supports both). What price do comparable macOS utilities sell at, and what does the fixed 40¢ do to a low price?
9. Discounts, coupons, purchase-power parity, and whether a free trial is worth building.

**Legal and trust**
10. What buyer data does Polar hold, what does the seller see, and what must the site's privacy line say once purchases exist?
11. Licence key storage in the app: Keychain, and what happens on reinstall or migration to a new Mac.

## Deliverable

A one-page decision on this ticket: which option, the exact wording the site and README would carry, the fee and net numbers at the chosen price, the six-step integration plan already sketched at the end of `docs/licensing.md`, and the risks that remain (leaked keys, disputes, support load).

## Out of scope

Building anything. No licensing code, no product page, no copy changes on the live site until the decision is made. Ponte 1.1.0 stays free and published while this is researched.

## Links

- GitHub issue: `charlesponti/ponte#1`
- Analysis and recommendation: `docs/licensing.md` in the Ponte repo
- Live product: https://charlesponti.github.io/ponte
- Release: https://github.com/charlesponti/ponte/releases/tag/v1.1.0
- Unrelated parked work: WYA-218 (voice commands)
