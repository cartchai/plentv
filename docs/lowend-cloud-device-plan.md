# Cloud-device plan (L-58 / T4-9) — spending decision, not code

No purchase is made by this work. Prices checked against vendor pages
via public search, Nov 2026 — re-verify before spending; all of them change.

## The short version

- **Firebase Test Lab:** use the free tier while it lasts, do NOT invest.
  It **shuts down 30 Sep 2027**; its replacement (Google Cloud's
  Developer Device Platform) had unpublished pricing at research time.
  No low-end (1–2 GB) or TV devices in the catalog.
- **AWS Device Farm:** the per-release phone matrix. ~**$5.10/release**
  on real low-end phones (Moto G Play, Galaxy A14). First ~30 releases
  are free inside the one-time 1,000 free minutes.
- **BrowserStack:** only if manual exploratory testing across many
  phone models is specifically needed. Subscription, not pay-per-minute.
- **Fire TV / Android TV:** **no cloud service rents them.** Buy one
  Fire Stick 4K Max 2nd gen (~$35–60) for the 2 GB tier — the cheapest
  real TV proof that exists.

## Per service

| Service | Price (Nov 2026) | Use for PlenTV | Cannot do |
|---|---|---|---|
| Firebase Test Lab | Blaze: 60 virtual min/day + 30 physical min/day free, then $1/device-hour virtual, $5/device-hour physical. Spark: 10 virtual + 5 physical runs/day. **Deprecated — shuts down 30 Sep 2027.** | Cheapest phone matrix while it lasts. Robo test crawls the app; instrumentation tests run the fixture pack; logcat + screenshots + video per run. Good for "does 1.2.19 crash on a Pixel 7 / Galaxy A-series" smoke. | No Fire TV, no Android TV, no 1–2 GB low-end devices. Virtual devices have fixed per-model specs — RAM cannot be set to 1536 MB. No D-pad/TV navigation in Robo. No memory graph of its own — RSS must come from the in-app dump/logcat. |
| AWS Device Farm | **$0.17/device-minute** after a one-time 1,000 free minutes; or $250/device-slot/month unmetered; private devices from $200/mo. Remote-access sessions bill the same meter. | **Best pay-per-minute real-phone option.** Real phones/tablets (1,000+ devices incl. older Samsung/LG/Motorola — the closest thing to a real low-end phone pool). Remote access = drive the app by hand on a real low-end phone. Returns logs, screenshots, video, performance data per run. Per-release 10-min scripted run on 2–3 real low-end phones: 3 × 10 min × $0.17 ≈ **$5.10**. | No Fire TV, no Android TV sticks. Test packages need a test spec (YAML) + uploaded APK; setup is heavier than FTL. Per-minute cost punishes long soak runs: a 30-min soak on 3 devices = 90 min = $15.30. |
| BrowserStack App Live / App Automate | App Live $39/mo (1 user, unlimited interactive, billed annually); Team $150/mo; App Automate $199/mo per parallel. Free tier: 100 App Automate minutes. Network throttling only on Team+. | Largest real-device library (2,500+ Android). App Live = manual exploratory on a real phone by hand — the right tool for "reproduce the owner's exact report on a Galaxy A-series". | TV coverage thin/absent — verify before buying; do not assume a Fire Stick or Android TV exists in the fleet. Subscription, not pay-per-minute: $39/mo is wasted in a month with no release. Terms forbid publishing performance results (internal use is fine). |
| TestMu AI, Sauce Labs, Kobiton | From ~$15–39/mo. | Same shape as BrowserStack: real phones, manual + automated. | Same TV gap. Another subscription to manage. Backups, not first choices. |
| Bought Fire Stick 4K Max 2nd gen | **~$60 list, routinely $35–50 on sale.** One-time. | The ONLY item here that runs Fire OS on 2 GB RAM with the real LMK, real eMMC, real Wi-Fi, and the real remote. Every TV-tier claim in every report is unverified until this exists. | One device, one OS version (Fire OS 8 / Android 11), no automation without extra work (Appium over ADB works, but setup is manual). |

## Per-release plan

1. FTL virtual smoke on the free tier while it lasts (instrumentation
   test with the fixture pack, ~10 min, $0).
2. AWS Device Farm 10-min scripted run on 2–3 real low-end phones per
   release (~$5.10, inside the one-time 1,000 free minutes for the
   first ~30 releases).
3. No BrowserStack subscription unless manual exploratory across many
   phone models is specifically needed.
4. One Fire Stick 4K Max 2nd gen bought once (~$35–60) for the only
   real 2 GB TV measurement that exists.

## Rules for every cloud run (Trex ban)

No live panel use, ever. Cloud runs use the fixture pack + mock server
only (`tool/generate_trex_fixture.dart`, `tool/mock_xtream_server.dart`):
seeded disk files and canned Xtream responses served from a host the
test controls. A cloud device must never hold a real login, and a test
that needs the network must fail closed (refusal/timeout) rather than
reach the real panel. The mock server is also what makes cloud runs
reproducible — the same canned feed every time, instead of a live feed
that changes between runs.

## The coverage gap, stated plainly

No cloud service in this table rents Fire TV sticks or built-in Android
TVs. The TV tier (1.5 GB Hisense + 2 GB Fire Stick) can only be proven
on hardware the owner already owns (the Hisense) plus one ~$50 stick. Any
plan that claims cloud coverage of the TV tier is wrong.
