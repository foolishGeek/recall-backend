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

## Prerequisites (block on these)

### Wave A — RC staging

- [ ] Signed AAB for `app.recall.staging` on Play **Internal testing** (or Internal app sharing); install via Play opt-in link (not a debug sideload).
- [ ] Play products **Active**: `recall_premium_monthly`, `recall_premium_yearly`, `ai_credits_100`, `ai_credits_500`.
- [ ] RevenueCat staging app linked to Play **service-account JSON** + Real-Time Developer Notifications.
- [ ] **License testers** added (accelerated renewals: monthly ~5 min; auto-cancel after ~6 cycles).
- [ ] Staging dart-defines / `config/staging.json` with staging `REVENUECAT_API_KEY`.
- [ ] Staging webhook URL: `https://vxbqzzebiuxzywmekdex.supabase.co/functions/v1/revenuecat-webhook`.

### Wave B — RC prod (after A)

- [ ] Prod Play app `app.recall` + Active products + service account + RTDN.
- [ ] Prod RC entitlement `premium`, offering `default`, same 4 SKUs.
- [ ] Webhook → `https://cpyhkjourabizancgkjm.supabase.co/functions/v1/revenuecat-webhook` with a **prod-dedicated** Authorization secret (replace the placeholder on Recall-prod).
- [ ] Real `REVENUECAT_REST_API_KEY` on prod EF secrets.
- [ ] `config/prod.json` `REVENUECAT_API_KEY` = prod public SDK key.

---

## Checklist A–G (run on Wave A first)

### A. Config sanity

- [ ] Paywall shows live monthly + yearly `priceString` (not “Price unavailable”).
- [ ] RC dashboard customer `app_user_id` == Supabase user UUID (`Purchases.logIn`).

### B. Webhook plumbing

- [ ] RC → Integrations → Webhooks → **Send test event** → staging EF returns 200.
- [ ] `supabase functions logs revenuecat-webhook --project-ref vxbqzzebiuxzywmekdex` shows handled event.

### C. Sandbox purchase

- [ ] License tester buys Premium monthly.
- [ ] RC: `INITIAL_PURCHASE`, environment `SANDBOX`, entitlement `premium` active.
- [ ] DB: `subscriptions.tier=premium`, `will_renew=true`, `expires_at` set; `profiles.had_premium=true`.
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

## SKUs / entitlement (canonical)

| ID | Type |
|----|------|
| `recall_premium_monthly` | subscription |
| `recall_premium_yearly` | subscription (−20% vs 12× monthly) |
| `ai_credits_100` | consumable |
| `ai_credits_500` | consumable |
| Entitlement | `premium` |
| Offering | `default` |

---

## Related

- App: `recall-mobile/lib/data/services/revenuecat_service.dart`
- EF: `recall-backend/supabase/functions/revenuecat-webhook/`
- SQL: `00025_revenuecat_webhook.sql`
- Sprint: [`Roadmap/sprints/S23-paywall.md`](../../Roadmap/sprints/S23-paywall.md)
