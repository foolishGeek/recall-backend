// auth-send-email — Auth "Send Email" hook.
// Bypasses GoTrue's built-in template renderer (which was falling back to the
// default plain "Confirm your email address" on this free-tier project even
// with Custom SMTP + custom templates stored) and sends the branded Recall
// magic-link HTML via SMTP2GO. Handles signup + magiclink + invite the same
// way (passwordless app — all are "click to sign in").
// Deployed with verify_jwt = false; Auth signs the request with the webhook secret.

import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import { sendSmtp } from "../_shared/smtp.ts";

// Supabase edge runtime global: keeps the worker alive for a background task
// after the response is returned.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const SUBJECT = "Your sign-in link to Recall";

type EmailData = {
  token: string;
  token_hash: string;
  redirect_to: string;
  email_action_type: string;
  site_url: string;
  token_new?: string;
  token_hash_new?: string;
};

type HookPayload = {
  user: { email: string };
  email_data: EmailData;
};

function confirmationUrl(
  supabaseUrl: string,
  emailData: EmailData,
): string {
  const type = emailData.email_action_type || "magiclink";
  const redirect = encodeURIComponent(emailData.redirect_to || "");
  return `${supabaseUrl}/auth/v1/verify?token=${emailData.token_hash}&type=${type}&redirect_to=${redirect}`;
}

function brandedHtml(confirmUrl: string, markBase: string): string {
  const tile = `${markBase}/recall-mark-tile.png`;
  const muted = `${markBase}/recall-mark-muted.png`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>Sign in to Recall</title>
<!--[if mso]>
<style type="text/css">
  body, table, td, a { font-family: Arial, Helvetica, sans-serif !important; }
</style>
<![endif]-->
<style type="text/css">
  body { margin:0; padding:0; width:100% !important; -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%; }
  table { border-collapse:collapse; }
  img { border:0; line-height:100%; outline:none; text-decoration:none; }
  a { text-decoration:none; }
  .lnk:hover { color:#111111 !important; }
  @media only screen and (max-width:620px) {
    .container { width:100% !important; }
    .px { padding-left:28px !important; padding-right:28px !important; }
    .h1 { font-size:38px !important; line-height:1.04 !important; }
  }
</style>
</head>
<body style="margin:0; padding:0; background-color:#e7e5df;">
  <span style="display:none; visibility:hidden; opacity:0; color:transparent; height:0; width:0; overflow:hidden; mso-hide:all;">Your secure sign-in link for Recall — it opens the app and expires in 15 minutes.</span>
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#e7e5df;">
    <tr>
      <td align="center" style="padding:48px 16px 64px 16px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px;">
          <tr>
            <td align="center" style="padding-bottom:30px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center">
                <tr>
                  <td valign="middle" style="padding-right:13px;">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td width="46" height="46" align="center" valign="middle" style="width:46px; height:46px; text-align:center; line-height:0;">
                          <img src="${tile}" width="46" height="46" alt="Recall" style="display:block; width:46px; height:46px; border:0;">
                        </td>
                      </tr>
                    </table>
                  </td>
                  <td valign="middle" style="font-family:Georgia,'Times New Roman',serif; font-weight:bold; font-size:29px; letter-spacing:0.4px; color:#111111;">Recall</td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px; background-color:#ffffff; border-radius:26px;">
          <tr>
            <td class="px" style="padding:56px 56px 12px 56px;">
              <div style="font-family:'Courier New',Courier,monospace; font-size:11px; letter-spacing:3px; text-transform:uppercase; color:#8A8780;">Secure sign-in</div>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:18px 56px 0 56px;">
              <div class="h1" style="font-family:Georgia,'Times New Roman',serif; font-size:46px; line-height:1.02; letter-spacing:-0.5px; color:#111111;">One calm<br>way in.</div>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:22px 56px 0 56px;">
              <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:16px; line-height:1.65; color:#5C5A55;">Tap the button below to sign in to Recall. No password to remember — the link does the work.</p>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:34px 56px 0 56px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="center" bgcolor="#111111" style="border-radius:16px;">
                    <a href="${confirmUrl}" target="_blank" style="display:block; padding:18px 40px; font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#F7F6F3; border-radius:16px;">Sign in to Recall&nbsp;&nbsp;&rarr;</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:26px 56px 0 56px;">
              <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:13.5px; line-height:1.6; color:#8A8780;">This link expires in <span style="color:#5C5A55;">15 minutes</span> and can be used once. If it stops working, request a fresh one from the app.</p>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:32px 56px 0 56px;">
              <div style="height:1px; background-color:#ece9e3; line-height:1px; font-size:1px;">&nbsp;</div>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:24px 56px 56px 56px;">
              <p style="margin:0 0 8px 0; font-family:'Courier New',Courier,monospace; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#8A8780;">Button not working?</p>
              <p style="margin:0; font-family:'Courier New',Courier,monospace; font-size:12.5px; line-height:1.6; color:#5C5A55; word-break:break-all;">${confirmUrl}</p>
            </td>
          </tr>
        </table>
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px;">
          <tr>
            <td align="center" style="padding:26px 40px 0 40px;">
              <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:1.6; color:#8A8780;">Didn't try to sign in? You can safely ignore this email — nothing will happen without this link.</p>
            </td>
          </tr>
        </table>
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px;">
          <tr>
            <td align="center" style="padding:34px 40px 0 40px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin-bottom:14px;">
                <tr>
                  <td width="30" height="30" align="center" valign="middle" style="width:30px; height:30px; text-align:center; line-height:0;">
                    <img src="${muted}" width="22" height="22" alt="" style="display:inline-block; width:22px; height:22px; border:0; vertical-align:middle;">
                  </td>
                </tr>
              </table>
              <div style="font-family:Georgia,'Times New Roman',serif; font-style:italic; font-size:16px; color:#8A8780;">Forget forgetting.</div>
              <p style="margin:14px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; line-height:1.7; color:#a7a49d;">Recall by Ripple Labs&nbsp;&nbsp;·&nbsp;&nbsp;This is a no-reply address<br>Made with &#128420; from India</p>
              <p style="margin:10px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; line-height:1.7; color:#a7a49d;">
                <a href="mailto:contact@ripplelabs.in" class="lnk" style="color:#8A8780; text-decoration:underline;">Help</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://recall.app/privacy" class="lnk" style="color:#8A8780; text-decoration:underline;">Privacy</a>
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
    });
  }

  const hookSecret = Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "";
  const smtpUser = Deno.env.get("SMTP2GO_USER") ?? "no-reply@ripplelabs.in";
  const smtpPass = Deno.env.get("SMTP2GO_PASS") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";

  if (!hookSecret || !smtpPass || !supabaseUrl) {
    console.error("missing SEND_EMAIL_HOOK_SECRET / SMTP2GO_PASS / SUPABASE_URL");
    return new Response(
      JSON.stringify({
        error: { message: "server misconfigured", http_code: 500 },
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const payload = await req.text();
  const headers = Object.fromEntries(req.headers);
  const wh = new Webhook(hookSecret.replace("v1,whsec_", ""));

  let parsed: HookPayload;
  try {
    parsed = wh.verify(payload, headers) as HookPayload;
  } catch (err) {
    console.error("webhook verify failed", err);
    return new Response(
      JSON.stringify({
        error: { message: "invalid webhook signature", http_code: 401 },
      }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const { user, email_data } = parsed;
  const action = email_data.email_action_type;
  // Passwordless sign-in emails share one branded template.
  const signInActions = new Set(["signup", "magiclink", "invite", "email"]);
  if (!signInActions.has(action)) {
    // Still deliver a minimal branded sign-in style for recovery/etc. for now,
    // so nothing falls back to GoTrue defaults.
    console.log(`sending branded template for action=${action}`);
  }

  const url = confirmationUrl(supabaseUrl, email_data);
  const markBase =
    `${supabaseUrl}/storage/v1/object/public/brand-assets`;
  const html = brandedHtml(url, markBase);

  // Send in the background and return 200 immediately. The GoTrue Send Email
  // hook has a short response timeout; a slow STARTTLS handshake (especially on
  // a cold start) can exceed it, making the app show a failed magic-link request
  // even though SMTP2GO already accepted the message and the email arrives.
  // Deferring the send keeps the hook fast so the app reliably reflects success.
  // The hook only fires when GoTrue has already generated a valid link, so the
  // email is still only triggered on a successful magic-link request.
  const send = sendSmtp({
    host: "mail.smtp2go.com",
    port: 587,
    user: smtpUser,
    pass: smtpPass,
    from: `Recall <${smtpUser}>`,
    to: user.email,
    subject: SUBJECT,
    html,
  }).catch((err) => {
    console.error("auth-send-email: smtp send failed", err);
  });

  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(send);
  } else {
    await send;
  }

  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
