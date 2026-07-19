# S23 Smoke — RevenueCat / Play Billing

**Sprint:** S23 Paywall · **Depends on:** Recall-prod cutover ([`PROD-DEPLOYMENT-DEFERRED.md`](PROD-DEPLOYMENT-DEFERRED.md))  
**Canon:** `[D-PAY-1]` `[D-PAY-2]` · Chain: Play → RevenueCat → `revenuecat-webhook` → `apply_revenuecat_event()` → `subscriptions` / `profiles` / `ai_credit_ledger`

## Strategy (A then B)

| Wave | RC project | Play package | App dart-define | Webhook target |
|------|------------|--------------|-----------------|----------------|
| **A (first)** | Staging | `app.recall.staging` | staging `REVENUECAT_API_KEY` (`goog_…`) | staging Supabase `vxbqzzebiuxzywmekdex` |
| **B (later)** | Prod | `app.recall` | prod `REVENUECAT_API_KEY` | Recall-prod `cpyhkjourabizancgkjm` |

Wave A proves the purchase → webhook → tier code path. Wave B proves the launch billing path against Recall-prod.

---

## Locked staging Play store IDs (Wave A)

| Play / RC store identifier | Play product | Base plan | Type |
|----------------------------|--------------|-----------|------|
| `recall_premium_monthly:recall-01` | `recall_premium_monthly` | `recall-01` | subscription → entitlement `premium` |
| `recall_premium_yearly:recall-02` | `recall_premium_yearly` | `recall-02` | subscription → entitlement `premium` |
| `ai_credits_100` | `ai_credits_100` | — | consumable (+100) |
| `ai_credits_500` | `ai_credits_500` | — | consumable (+500) |

- Entitlement `premium`: **only** the two subscriptions (credits = 0 entitlements).
- Offering `default` (Current): monthly → `recall_premium_monthly:recall-01`, annual → `recall_premium_yearly:recall-02`.
- App matches bare id **or** `product:basePlan` via `RevenueCatService.matchesProductId`.

If RC shows **Not found**: products are missing/Draft in Play for `app.recall.staging`, or AAB not on a testing track. Activate in Play → wait → Import/refresh in RC.

---

## Prerequisites (block on these)

### Wave A — RC staging

- [x] RC service-account JSON uploaded → **Valid credentials** (catalog + purchases API).
- [x] RTDN connected (`projects/recall-spaced-staging/topics/…`) + Play test notification sent (grant `google-play-developer-notifications@system.gserviceaccount.com` **Pub/Sub Publisher** on the topic if Play test fails).
- [x] Staging `config/staging.json` `REVENUECAT_API_KEY` (`goog_…`).
- [x] Staging webhook URL: `https://vxbqzzebiuxzywmekdex.supabase.co/functions/v1/revenuecat-webhook`.
- [ ] Play products **Active** with exact IDs above (fix RC **Not found**).
- [ ] Signed AAB for `app.recall.staging` on Play **Internal testing**; install via Play opt-in (not sideload).
  - Local build ready: `recall-mobile/build/app/outputs/bundle/stagingRelease/app-staging-release.aab` (upload to Internal testing).
- [ ] **License testers** added (`RESPOND_NORMALLY`).
- [ ] Offering `default` Current with monthly + yearly packages wired to the locked store ids.
- [ ] Credits detached from `premium` in RC.

### Wave B — RC prod (after A)

- [ ] Prod Play app `app.recall` + Active products (same product ids; base plans may reuse `recall-01`/`recall-02` or new ids — update app constants if base plans differ).
- [ ] Prod RC entitlement `premium`, offering `default`, same catalog.
- [ ] Webhook → `https://cpyhkjourabizancgkjm.supabase.co/functions/v1/revenuecat-webhook` with a **prod-dedicated** Authorization secret.
- [ ] Real `REVENUECAT_REST_API_KEY` on prod EF secrets.
- [ ] `config/prod.json` `REVENUECAT_API_KEY` = prod public SDK key (`goog_…`).

---

## Checklist A–G (run on Wave A first)

### A. Config sanity

- [ ] Paywall shows live monthly + yearly `priceString` (not “Price unavailable”).
- [ ] RC dashboard customer `app_user_id` == Supabase user UUID (`Purchases.logIn`).

### B. Webhook plumbing

- [ ] RC → Integrations → Webhooks → **Send test event** → staging EF returns 200.
- [ ] `supabase functions logs revenuecat-webhook --project-ref vxbqzzebiuxzywmekdex` shows handled event.

### C. Sandbox purchase

- [ ] License tester buys Premium monthly (`recall_premium_monthly:recall-01`).
- [ ] RC: `INITIAL_PURCHASE`, environment `SANDBOX`, entitlement `premium` active.
- [ ] DB: `subscriptions.tier=premium`, `will_renew=true`, `expires_at` set; `profiles.had_premium=true`; `product_id` may be the full Play store id.
- [ ] App tier flips within ~60s (webhook) or sooner via `getCustomerInfo()` fast-path.

### D. Lifecycle (accelerated clock)

- [ ] `RENEWAL` advances `expires_at`.
- [ ] Cancel in Play → `CANCELLATION` → still premium, `will_renew=false`.
- [ ] Let expire → `EXPIRATION` → `tier=free` + S26 downgrade rules (see [`S26-SMOKE.md`](S26-SMOKE.md)).

### E. Restore

- [ ] Reinstall / clear data → sign in → Restore purchases → entitlement returns.

### F. Consumables + idempotency

- [ ] As premium, buy `ai_credits_100` → `NON_RENEWING_PURCHASE` → balance += 100 + one ledger row.
- [ ] Replay same `event.id` → no double credit.
- [ ] Non-premium credit purchase rejected `[D-PAY-2]`.

### G. Edge cases

- [ ] User cancels store sheet → no error toast, stay on paywall.
- [ ] Store unreachable / no offerings → “Price unavailable”, CTA disabled.
- [ ] `BILLING_ISSUE` → tier unchanged, `will_renew=false`.

---

## Prod money gate (Wave B only)

- [ ] One Closed-testing (or Internal) purchase on `app.recall` against Recall-prod.
- [ ] Confirm webhook lands on `cpyhkjourabizancgkjm` and flips `subscriptions`.
- [ ] Refund / expire and confirm downgrade path.
- [ ] Do **not** ship public Production track until A–G + this gate pass.

---

## App Store (deferred)

Blocked until Apple Developer enrollment (S00). When ready: same 4 product ids in App Store Connect (no Play base-plan suffix), RC iOS app + `appl_…` key, sandbox purchase/restore mirroring Wave A. Do not block Android Wave A on this.
- EF: `recall-backend/supabase/functions/revenuecat-webhook/`
- SQL: `00025_revenuecat_webhook.sql`, `00042_revenuecat_product_base_plan.sql`, `00043_limits_profile_relaxed.sql`
- Limits rollback while payments settle: [`LIMITS-ROLLBACK.md`](LIMITS-ROLLBACK.md)
- Sprint: [`Roadmap/sprints/S23-paywall.md`](../../Roadmap/sprints/S23-paywall.md)
