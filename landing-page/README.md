# Dubby waitlist site

The public landing page for Dubby, with the waitlist signup built in. It is plain HTML, CSS, and JavaScript with no build step, so Vercel serves this folder as is. Signups go to the `waitlist` table in our Convex deployment through `POST /waitlist` (`convex/waitlist.ts`, routed in `convex/http.ts`).

This is separate from `../landing/`, the informational site, which deliberately has no signup.

## Files

| File | What it is |
|---|---|
| `index.html` | The page, plus `<template>`s for the eight in-phone app screens |
| `styles.css` | Tokens copied from `erica-frontend/docs/style-guide.md` and all layout |
| `app.js` | Phone screens, scroll effects, the signup forms, and the Whop checkout |
| `config.js` | The Convex endpoint and Whop plan ID (both public values) |
| `assets/LeagueGothic.ttf` | Wordmark and poster face (SIL OFL, licence beside it) |
| `assets/scenes/*.webp` | Film stills used as posters and video frames (see Images) |
| `og.png`, `favicon.svg` | Share preview and tab icon |

## Run locally

```sh
cd landing-page
python3 -m http.server 4321
```

Open http://localhost:4321. Asset paths start with `/`, so serve this folder as the site root rather than opening the file directly.

## Connect signups (Convex)

1. Deploy the backend so the `waitlist` table and route exist: `npx convex deploy` from the repo root (or `npx convex dev` for a dev deployment).
2. In `config.js`, set `waitlistEndpoint` to the deployment's HTTP actions URL plus `/waitlist`, for example `https://happy-otter-123.convex.site/waitlist`. Use `.convex.site`, not `.convex.cloud`.
3. Signups appear in the Convex dashboard under Data → `waitlist`: email (lowercased, one row per email), plan (`free` or `founding`), language, source, and timestamps. A repeat signup with the founding plan upgrades the row; nothing ever downgrades it.

Until `waitlistEndpoint` is set, the forms say "Signups aren't open yet" instead of pretending to succeed.

`source` records `?utm_source=` or `?ref=` from the page URL, so links like `…/?utm_source=hackathon` tell you where signups came from.

## Take founding payments (Whop)

Founding signups pay in a Whop checkout embedded right in the signup section (Whop Elements, loaded from `https://cdn.whop.com/elements/amber/elements.js` only when needed). The free plan never shows it.

1. In the Whop dashboard (use `sandbox.whop.com` during the hackathon), create a product with a $4.99/month plan and copy its plan ID (`plan_…`).
2. Put it in `config.js` as `whopPlanId`.
3. Create a webhook in the Whop dashboard (Developer → Webhooks) for `payment.succeeded`, pointing at `https://<deployment>.convex.site/whop/webhook`.
4. Set its signing secret on the Convex deployment, exactly as Whop shows it (the `ws_…` string): `npx convex env set WHOP_WEBHOOK_SECRET ws_…`.

The flow:
- Someone picks Founding and submits. Convex saves them with `plan: "founding"`.
- Whop's checkout appears in place. The page passes their waitlist email as checkout `metadata.email`.
- When they pay, Whop calls `/whop/webhook`. Convex checks the signature, then sets `paidAt` and `whopPaymentId` on their row. Payers who never joined the waitlist are added.

The browser's "payment complete" message only updates the page; the webhook is what marks a row paid. Until `whopPlanId` is set, founding signups are recorded with no payment step. If you change the price, update it in `index.html` (plan card, FAQ) and the checkout heading in `app.js`.

## Deploy on Vercel

1. Import the GitHub repo in Vercel.
2. Set **Root Directory** to `landing-page` and **Framework Preset** to *Other*. Leave the build command empty.
3. Deploy. Every push to `main` redeploys.

## Images

Every poster, role card and video frame is a still from *Tears of Steel* (2012, Blender Foundation), licensed under CC BY 3.0. It's the same film as the app's demo scene, `Dubbing/DemoScenes/tears-of-steel-bridge` (license notes in `docs/demo-scenes.md`). The credit in the page footer is required by the license; keep it whenever these stills are shown.

- `tos-bridge-*.webp` come from the app's bridge clip.
- The rest were cut from the official 720p release (`tears_of_steel_720p.mov`, the sha256 pinned in `scripts/demo-scenes/prepare-tears-of-steel-bridge.sh`) at these timestamps: celia-close 320 s, thom-arm 395 s, cyborg 560 s, soldier 365 s, sniper 140 s, robot-bridge 515 s, hacker 305 s, duo 215 s.
- Scene titles other than "The Bridge" (The Lab, Last Stand, Overwatch) are names given on this page, not scenes the app ships yet.

**Swapping images:** any element with `style="--img:url(...)"` shows that image and falls back to its `--a`/`--b` colour gradient without one. Use only footage you have rights to, and update the footer credit to match. Studio films need a license; a screenshot doesn't make them usable.

## Content notes

- App screens are HTML recreations of the `erica-frontend` screens, filled with the bridge scene's real characters and dialogue. The page says they are previews of an app in development.
- Pricing and plan features are draft copy. The iMessage screen shows the planned Keiki agent invite; it is a preview, not a working integration yet.
- Red appears only on recording UI and cyan only on the coach, matching the app's style guide.
