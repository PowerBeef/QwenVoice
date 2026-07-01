# Donations setup (maintainer checklist)

Vocello exposes two donation paths for Canadian maintainers:

| Platform | Audience | Fees (tips) | Payout |
| --- | --- | --- | --- |
| [GitHub Sponsors](https://github.com/sponsors/PowerBeef) | GitHub users | 0% platform fee (personal account) | Canadian bank via Stripe |
| [Ko-fi](https://ko-fi.com/PowerBeef) | Everyone (guest checkout) | 0% platform fee on tips | Stripe and/or PayPal |

Repo wiring is already in place:

- `.github/FUNDING.yml` — GitHub **Sponsor** button on the repository
- `README.md` — Support section and sponsor badge
- `website/src/data/credits.js` — footer links on [vocello.vercel.app](https://vocello.vercel.app/)

Complete the steps below on the `PowerBeef` accounts so those links accept payments.

## 1. GitHub Sponsors (~15 minutes)

1. Sign in as **PowerBeef** and open [github.com/sponsors](https://github.com/sponsors).
2. Click **Get started** and create a sponsored developer profile.
3. Enable **two-factor authentication** on the GitHub account if it is not already on.
4. Add a short bio (what Vocello is, that it is local/open source on Apple Silicon).
5. Create at least one sponsorship tier (a single **$5/month** tier plus a **custom amount** one-time option is enough to start).
6. Connect payout details:
   - **Country:** Canada
   - **Bank:** Canadian chequing account (transit, institution, account number)
   - **Tax:** submit **W-8BEN** when prompted (country of residence Canada; foreign tax ID = SIN)
7. Submit the profile and wait for GitHub review if required.
8. Verify: open [github.com/PowerBeef/QwenVoice](https://github.com/PowerBeef/QwenVoice) and confirm the **Sponsor** button appears in the sidebar.

## 2. Ko-fi (~10 minutes)

1. Sign up at [ko-fi.com](https://ko-fi.com) and claim the **`PowerBeef`** page URL (`ko-fi.com/PowerBeef`).
2. Set display name to **Vocello** (or **PowerBeef / Vocello**).
3. Add a one-line description, for example: *Local, private text-to-speech for Apple Silicon. Open source.*
4. Under **Payment settings**, connect **Stripe** (recommended) and optionally **PayPal** for donors who prefer it.
5. Complete Stripe identity verification with your Canadian bank details.
6. Leave Ko-fi on the **free** plan unless you want Gold branding features; tips stay at 0% platform fee.
7. Verify: open [ko-fi.com/PowerBeef](https://ko-fi.com/PowerBeef) in a private window and run a **$1 test tip** (refund yourself afterward if you like).

## 3. After both are live

- Merge the donations PR so `main` carries the updated `FUNDING.yml`, README, and website footer.
- Redeploy the marketing site (Vercel auto-deploys on push to `main`).
- Optional: mention support in the next GitHub Release notes.

## Tax note (Canada)

GitHub Sponsors and Ko-fi/Stripe do not withhold Canadian income tax. Track payouts for your own CRA reporting. GitHub Sponsors uses a U.S. W-8BEN for treaty purposes; Ko-fi payouts flow through Stripe/PayPal with their own tax forms.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| No **Sponsor** button on the repo | Confirm `FUNDING.yml` is on `main` and the GitHub Sponsors profile is **published**. |
| Ko-fi link shows a generic landing page | The `PowerBeef` page is not claimed yet; finish Ko-fi signup with that username. |
| Stripe asks for extra verification | Normal for first payout; allow 2–7 days. |
| Donor cannot use PayPal on Ko-fi | Connect PayPal in Ko-fi payment settings, or point them to GitHub Sponsors instead. |
