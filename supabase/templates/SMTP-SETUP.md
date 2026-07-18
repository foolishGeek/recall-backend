# Email Template & SMTP Setup

## How auth emails are sent (staging — live)

GoTrue's built-in template renderer was falling back to the default plain
"Confirm your email address" email on this free-tier project even after Custom
SMTP + custom templates were stored via the Management API. So branding is
owned by the **Send Email Auth Hook**, not GoTrue templates:

1. App calls `signInWithOtp` (new or returning user).
2. Auth invokes Edge Function `auth-send-email` (HTTPS hook).
3. The function builds the branded HTML (same design as
   `templates/magic_link.html`) and sends it via SMTP2GO
   (`mail.smtp2go.com:587`, from `no-reply@ripplelabs.in`).

| Piece | Value |
|---|---|
| Function | [`supabase/functions/auth-send-email`](../functions/auth-send-email/index.ts) |
| Hook URI | `https://vxbqzzebiuxzywmekdex.supabase.co/functions/v1/auth-send-email` |
| Subject | `Your sign-in link to Recall` |
| Secrets | `SEND_EMAIL_HOOK_SECRET`, `SMTP2GO_USER`, `SMTP2GO_PASS` (EF secrets) |

`verify_jwt = false` for this function — Auth signs with the webhook secret.

Signup / magiclink / invite all use the same branded "One calm way in." design
(passwordless app).

### Redeploy / re-enable

```bash
# secrets (once per project)
supabase secrets set \
  SEND_EMAIL_HOOK_SECRET="v1,whsec_..." \
  SMTP2GO_USER="no-reply@ripplelabs.in" \
  SMTP2GO_PASS="..." \
  --project-ref vxbqzzebiuxzywmekdex

supabase functions deploy auth-send-email --project-ref vxbqzzebiuxzywmekdex --no-verify-jwt

# enable hook (Management API)
curl -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "hook_send_email_enabled": true,
    "hook_send_email_uri": "https://'"$REF"'.supabase.co/functions/v1/auth-send-email",
    "hook_send_email_secrets": "v1,whsec_..."
  }'
```

The HTML files under `templates/` remain the source of truth for the design
(and for local/dashboard reference). The Edge Function embeds the same markup.

## Onboarding lifecycle emails (welcome + founder) — via Zoho

Two branded emails fire after a user first *confirms* sign-up (Google insert or
magic-link verify), independent of the auth hook above:

| Email | When | From | Reply-To | Subject |
|---|---|---|---|---|
| Welcome | Instantly on first confirm | `Recall <contact@ripplelabs.in>` | — | `Welcome to Recall` |
| Founder note | ~15 min after sign-up | `Avijit from Ripple Labs <avijit@ripplelabs.in>` | `avijit@ripplelabs.in` | `A note from Avijit` |

Both use the same hosted-PNG brand marks as the magic link (no inline SVG), sent
over Zoho SMTP (`smtppro.zoho.in:587`, STARTTLS) via the shared client
[`_shared/smtp.ts`](../functions/_shared/smtp.ts).

### How it works

1. Migration [`00036_onboarding_emails.sql`](../migrations/00036_onboarding_emails.sql)
   adds the `onboarding_emails` **send-status ledger** (one row per user) and a
   pg_cron job `onboarding-emails-2min` (`*/2 * * * *`) as the guaranteed
   driver + retry safety net.
   [`00038_onboarding_on_app_session.sql`](../migrations/00038_onboarding_on_app_session.sql)
   enqueues on the user's **first `app_sessions` insert** (mobile client only
   writes that after it holds a real session). Do **not** key off
   `auth.users.confirmed_at` / `last_sign_in_at` — with autoconfirm, GoTrue sets
   those when the magic link is *requested*, so welcome was firing next to the
   magic-link email before the user clicked.
2. Edge Function [`onboarding-emails`](../functions/onboarding-emails/index.ts)
   (auth: `X-Cron-Secret`, `verify_jwt = false`) processes two queues each run:
   - Welcome: `welcome_sent_at IS NULL AND welcome_attempts < 6`.
   - Founder: welcome sent, `founder_sent_at IS NULL`, `founder_attempts < 6`,
     and `signup_at <= now() - 15 min`.
   A `*_sent_at` is written **only after a successful Zoho send**; failures leave
   it NULL, record `last_error`, and retry next run (capped at 6 attempts).

### Send-status ledger (`onboarding_emails`)

| Column | Meaning |
|---|---|
| `welcome_sent_at` / `founder_sent_at` | Timestamp the email was delivered (NULL = not sent yet) |
| `welcome_attempts` / `founder_attempts` | Send attempts so far (cap 6) |
| `last_attempt_at`, `last_error` | Last try + last failure reason (observability) |

`RLS` is on with no policies (service-role only). The seed guard in the migration
marks all currently-confirmed users as already sent, so existing users are never
emailed — only new confirmations from deploy time onward.

### Secrets (per project)

`ZOHO_CONTACT_USER` / `ZOHO_CONTACT_PASS` (authenticates + sends the welcome as
`contact@`) and `ZOHO_AVIJIT_USER` / `ZOHO_AVIJIT_PASS` (founder as `avijit@`).
Each mailbox authenticates as itself, so no alias/send-as config is needed.
Optional `ZOHO_SMTP_HOST` / `ZOHO_SMTP_PORT` override the defaults
(`smtppro.zoho.in` / `587`) if Zoho's regional host differs.

```bash
supabase secrets set \
  'ZOHO_CONTACT_USER=contact@ripplelabs.in' 'ZOHO_CONTACT_PASS=...' \
  'ZOHO_AVIJIT_USER=avijit@ripplelabs.in'   'ZOHO_AVIJIT_PASS=...' \
  --project-ref <ref>

supabase functions deploy onboarding-emails --project-ref <ref> --no-verify-jwt
supabase db push   # applies 00036 (needs Vault app_supabase_url + app_cron_secret)
```

> If a send ever fails with a `535` auth error, the mailbox likely has 2FA on —
> generate a Zoho **app-specific password** and swap it into the `*_PASS` secret
> (no code change). As of setup, the plain mailbox passwords authenticate fine.

Template source-of-truth files: [`templates/welcome.html`](welcome.html) +
[`templates/founder.html`](founder.html) (staging URLs) and `templates/prod/`
copies (prod URLs). The Edge Function embeds the same markup and derives the mark
host from `SUPABASE_URL`, so it works on both envs automatically.

## Applying branded templates to hosted projects (dashboard reference)

If you ever disable the Send Email hook and rely on GoTrue templates again:

### Staging (Recall-Stage)

1. Go to https://supabase.com/dashboard/project/vxbqzzebiuxzywmekdex/auth/templates
2. For each template type (Magic Link, Confirm signup, Reset password, Change email, Invite):
   - Copy the HTML from the matching file in `recall-backend/supabase/templates/`
   - Paste into the "Body" editor
   - Update the "Subject" to match the subject in `config.toml`
3. Save each template

| Template | File | Subject |
|---|---|---|
| Magic Link | `magic_link.html` | Your sign-in link to Recall |
| Confirm signup | `confirmation.html` | Your sign-in link to Recall |
| Reset password | `recovery.html` | Reset your Recall password |
| Change email | `email_change.html` | Confirm your new email for Recall |
| Invite user | `invite.html` | You've been invited to Recall |

> Note: Recall is passwordless. Without the Send Email hook, `signInWithOtp`
> sends **Confirm signup** to brand-new users and **Magic Link** to returning
> users — brand both the same.

### Production (Recall-Prod)

1. Resume the project if inactive, upload mark PNGs to `brand-assets`, deploy
   `auth-send-email`, set the same EF secrets, enable the Send Email hook.
2. Use `templates/prod/` if falling back to GoTrue templates (prod logo URLs).

## Logo assets

Hosted in the `brand-assets` public Storage bucket on each project. The Magic Link
template uses hosted PNGs (not inline SVG) so the mark renders in Gmail, Apple Mail,
and Outlook. Source SVGs + generated PNGs live in `templates/assets/`:

| Asset | Used in | Colours | Source |
|---|---|---|---|
| `recall-mark-tile.png` (138x138, shown 46x46) | Magic Link header | `#111111` rounded tile + `#F7F6F3` mark | `assets/recall-mark-tile.svg` |
| `recall-mark-muted.png` (66x66, shown 22x22) | Magic Link footer | muted `#a7a49d` mark, transparent | `assets/recall-mark-muted.svg` |
| `recall-mark-120.png` | older templates | ink mark on transparent | — |

Public URLs:

- **Staging:** `https://vxbqzzebiuxzywmekdex.supabase.co/storage/v1/object/public/brand-assets/<file>`
- **Production:** `https://cpyhkjourabizancgkjm.supabase.co/storage/v1/object/public/brand-assets/<file>`

The staging templates reference the staging URL; the `prod/` templates reference the production URL.

### Regenerating / re-uploading the mark PNGs

```bash
cd recall-backend/supabase/templates/assets
rsvg-convert -w 138 -h 138 recall-mark-tile.svg  -o recall-mark-tile.png
rsvg-convert -w 66  -h 66  recall-mark-muted.svg -o recall-mark-muted.png

# Upload to a project's public brand-assets bucket (repeat per env with its secret key)
for f in recall-mark-tile.png recall-mark-muted.png; do
  curl -X POST "$SUPABASE_URL/storage/v1/object/brand-assets/$f" \
    -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
    -H "apikey: $SUPABASE_SECRET_KEY" \
    -H "x-upsert: true" -H "Content-Type: image/png" \
    --data-binary "@$f"
done
```

## Sender email — SMTP2GO relay

Mail is sent from `no-reply@ripplelabs.in` by relaying Supabase Auth through
**SMTP2GO** as a Custom SMTP server. Supabase still generates the magic link and
renders the template; it just hands delivery to SMTP2GO instead of its built-in
(rate-limited `@supabase.io`) server. No app code changes.

### 1. Domain (already done)

`ripplelabs.in` is verified in SMTP2GO (SPF/DKIM/CNAME records added and showing
verified). Nothing further to do here.

### 2. SMTP2GO credentials

From the SMTP2GO dashboard > **Sending > SMTP Users**, use the `no-reply@ripplelabs.in`
SMTP user:

- **Host:** `mail.smtp2go.com`
- **Port:** `587` (STARTTLS; SMTP2GO also offers 2525 / 8025 / 80 / 25, and SSL on 465 / 8465 / 443)
- **Username / Password:** the SMTP user's credentials (the password is set/reset on that SMTP Users page)

### 3. Configure in Supabase

For each project (staging + production):

1. Go to Authentication > Emails > SMTP Settings
2. Toggle **Enable Custom SMTP**
3. Fill in:
   - **Sender email:** `no-reply@ripplelabs.in`
   - **Sender name:** `Recall`
   - **Host:** `mail.smtp2go.com`
   - **Port:** `587`
   - **Username:** SMTP2GO SMTP user
   - **Password:** SMTP2GO SMTP user password
4. Save

Or via the Management API:

```bash
curl -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "smtp_admin_email": "no-reply@ripplelabs.in",
    "smtp_host": "mail.smtp2go.com",
    "smtp_port": 587,
    "smtp_user": "YOUR_SMTP2GO_USER",
    "smtp_pass": "YOUR_SMTP2GO_PASSWORD",
    "smtp_sender_name": "Recall"
  }'
```

### 4. Rate limits & expiry

- **Built-in (no SMTP):** 2 emails/hour (dev/testing only)
- **Custom SMTP:** 30 emails/hour default, adjustable in Auth > Rate Limits — raise it once SMTP2GO is enabled
- **SMTP2GO limits:** separate, per your plan
- **Magic link expiry:** set to `900` seconds (15 min) to match the template copy. Local: `otp_expiry` in `config.toml`. Hosted: Authentication > Emails (OTP expiry) or Management API (`mailer_otp_exp: 900`).

Once SMTP is configured, the Management API will also allow template updates programmatically.
