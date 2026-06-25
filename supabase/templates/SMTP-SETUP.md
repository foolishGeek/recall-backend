# Email Template & SMTP Setup

## Applying branded templates to hosted projects

The Management API blocks email template changes on the free tier.
Apply templates **manually through the Supabase Dashboard**.

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
| Confirm signup | `confirmation.html` | Confirm your Recall account |
| Reset password | `recovery.html` | Reset your Recall password |
| Change email | `email_change.html` | Confirm your new email for Recall |
| Invite user | `invite.html` | You've been invited to Recall |

### Production (Recall-Prod)

1. Go to https://supabase.com/dashboard/project/cpyhkjourabizancgkjm/auth/templates
2. Use the files from `recall-backend/supabase/templates/prod/` (these have the production logo URL)
3. Same subjects as above

## Logo assets

Hosted in the `brand-assets` public Storage bucket on each project:

- **Staging:** `https://vxbqzzebiuxzywmekdex.supabase.co/storage/v1/object/public/brand-assets/recall-mark-120.png`
- **Production:** `https://cpyhkjourabizancgkjm.supabase.co/storage/v1/object/public/brand-assets/recall-mark-120.png`

The staging templates reference the staging URL; the `prod/` templates reference the production URL.

## Changing the sender email (future)

To send from `no-reply@recall.app` instead of `@supabase.io`:

### 1. Choose an SMTP provider

| Provider | Free tier | Notes |
|---|---|---|
| **Resend** | 3,000 emails/month | Simplest setup, recommended |
| SendGrid | 100 emails/day | Established, good deliverability |
| Postmark | 100 emails/month | Developer-friendly |

### 2. Verify domain

Add DNS records to `recall.app` (exact records depend on provider):

- **DKIM** — cryptographic email signing
- **SPF** — authorized sender IPs
- **DMARC** — policy for failed checks (start with `p=none`)

### 3. Configure in Supabase

For each project (staging + production):

1. Go to Project Settings > Authentication > SMTP Settings
2. Toggle **Enable Custom SMTP**
3. Fill in:
   - **Sender email:** `no-reply@recall.app`
   - **Sender name:** `Recall`
   - **Host:** (from your provider, e.g. `smtp.resend.com`)
   - **Port:** `587`
   - **Username:** (from provider)
   - **Password:** (from provider)
4. Save

Or via the Management API:

```bash
curl -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "smtp_admin_email": "no-reply@recall.app",
    "smtp_host": "smtp.resend.com",
    "smtp_port": 587,
    "smtp_user": "resend",
    "smtp_pass": "re_YOUR_API_KEY",
    "smtp_sender_name": "Recall"
  }'
```

### 4. Rate limits

- **Built-in (no SMTP):** 2 emails/hour (dev/testing only)
- **Custom SMTP:** 30 emails/hour default, adjustable in Auth > Rate Limits
- **Provider limits:** Separate (e.g. Resend free = 3,000/month)

Once SMTP is configured, the Management API will also allow template updates programmatically.
