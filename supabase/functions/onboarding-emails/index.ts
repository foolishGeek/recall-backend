// onboarding-emails — lifecycle emails after a user first signs in on the client.
// Cron-driven (pg_cron every 2 min via invoke_onboarding_emails, 00036) and also
// pinged on the first app_sessions insert (00038/00040) — real client session,
// not magic-link request (autoconfirm sets auth.users too early). Auth: X-Cron-Secret
// header (no user JWT), like cleanup-exports. Two queues:
//   1. Welcome  — sent immediately on first client sign-in, from contact@ripplelabs.in.
//   2. Founder  — sent ~15 min after that sign-in, from avijit@ripplelabs.in.
// The onboarding_emails table is the send-status ledger: a *_sent_at is set only
// after a successful Zoho send, so failures stay queued and retry next run (up to
// an attempt cap). -> { welcomed, foundered, failed }.

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";
import { sendSmtp } from "../_shared/smtp.ts";

const WELCOME_SUBJECT = "Welcome to Recall";
const FOUNDER_SUBJECT = "A note from Avijit";
const FOUNDER_REPLY_TO = "avijit@ripplelabs.in";
const MAX_ATTEMPTS = 6;
const FOUNDER_DELAY_MIN = 15;
const BATCH = 100;

/** Constant-time string compare to avoid leaking the secret via timing. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function welcomeHtml(markBase: string): string {
  const tile = `${markBase}/recall-mark-tile.png`;
  const muted = `${markBase}/recall-mark-muted.png`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>Welcome to Recall</title>
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
    .h1 { font-size:42px !important; line-height:1.02 !important; }
    .step-num { font-size:20px !important; }
  }
</style>
</head>
<body style="margin:0; padding:0; background-color:#e7e5df;">

  <!-- preheader -->
  <span style="display:none; visibility:hidden; opacity:0; color:transparent; height:0; width:0; overflow:hidden; mso-hide:all;">Welcome to Recall — a calm, quiet way to remember what matters. Here's how to begin.</span>

  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#e7e5df;">
    <tr>
      <td align="center" style="padding:48px 16px 64px 16px;">

        <!-- brand lockup — mark hosted as a retina PNG so it renders in every client -->
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

        <!-- card -->
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px; background-color:#ffffff; border-radius:26px;">
          <tr>
            <td class="px" style="padding:56px 56px 0 56px;">
              <div style="font-family:'Courier New',Courier,monospace; font-size:11px; letter-spacing:3px; text-transform:uppercase; color:#8A8780;">Welcome aboard</div>
              <div class="h1" style="font-family:Georgia,'Times New Roman',serif; font-size:50px; line-height:1.0; letter-spacing:-0.5px; color:#111111; padding-top:18px;">Forget<br>forgetting.</div>
            </td>
          </tr>
          <tr>
            <td class="px" style="padding:24px 56px 0 56px;">
              <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:16px; line-height:1.65; color:#5C5A55;">You're in. Recall helps the things you learn actually stay — by resurfacing them at the exact moment you're about to forget. Quiet, unhurried, and built to fit into your day.</p>
            </td>
          </tr>

          <!-- button -->
          <tr>
            <td class="px" style="padding:34px 56px 0 56px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="center" bgcolor="#111111" style="border-radius:16px;">
                    <a href="https://recall.app/start" target="_blank" style="display:block; padding:18px 40px; font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#F7F6F3; border-radius:16px;">Open Recall&nbsp;&nbsp;&rarr;</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- hairline -->
          <tr>
            <td class="px" style="padding:44px 56px 0 56px;">
              <div style="height:1px; background-color:#ece9e3; line-height:1px; font-size:1px;">&nbsp;</div>
            </td>
          </tr>

          <!-- three steps -->
          <tr>
            <td class="px" style="padding:36px 56px 0 56px;">
              <div style="font-family:'Courier New',Courier,monospace; font-size:11px; letter-spacing:3px; text-transform:uppercase; color:#8A8780; padding-bottom:22px;">Three quiet steps</div>

              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td valign="top" width="52" style="font-family:Georgia,'Times New Roman',serif; font-size:22px; color:#C9C6C0;">01</td>
                  <td valign="top" style="padding-bottom:22px;">
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#111111; line-height:1.4;">Capture what matters</div>
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:14.5px; line-height:1.6; color:#5C5A55; padding-top:4px;">Drop in a note, a fact, or a question. Recall keeps it in a calm, tidy place.</div>
                  </td>
                </tr>
                <tr>
                  <td valign="top" width="52" style="font-family:Georgia,'Times New Roman',serif; font-size:22px; color:#C9C6C0;">02</td>
                  <td valign="top" style="padding-bottom:22px;">
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#111111; line-height:1.4;">Review, gently</div>
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:14.5px; line-height:1.6; color:#5C5A55; padding-top:4px;">A few cards a day, timed so each one lands right before it slips away.</div>
                  </td>
                </tr>
                <tr>
                  <td valign="top" width="52" style="font-family:Georgia,'Times New Roman',serif; font-size:22px; color:#C9C6C0;">03</td>
                  <td valign="top">
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#111111; line-height:1.4;">Watch it stick</div>
                    <div style="font-family:Arial,Helvetica,sans-serif; font-size:14.5px; line-height:1.6; color:#5C5A55; padding-top:4px;">Knowledge cools from hot to mastered. No streak pressure, no noise.</div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <tr>
            <td class="px" style="padding:40px 56px 56px 56px;">
              <div style="height:1px; background-color:#ece9e3; line-height:1px; font-size:1px;">&nbsp;</div>
              <p style="margin:22px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:13.5px; line-height:1.6; color:#8A8780;">Questions? Reach us anytime at <a href="mailto:contact@ripplelabs.in" class="lnk" style="color:#5C5A55; text-decoration:underline;">contact@ripplelabs.in</a> — a real person reads it.</p>
            </td>
          </tr>
        </table>

        <!-- footer -->
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
                <a href="https://ripplelabs.in/recall/help" class="lnk" style="color:#8A8780; text-decoration:underline;">Help</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://ripplelabs.in/recall/privacy" class="lnk" style="color:#8A8780; text-decoration:underline;">Privacy</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://ripplelabs.in/recall/tos" class="lnk" style="color:#8A8780; text-decoration:underline;">Terms</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://recall.app/unsubscribe" class="lnk" style="color:#8A8780; text-decoration:underline;">Unsubscribe</a>
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

function founderHtml(markBase: string): string {
  const tile = `${markBase}/recall-mark-tile.png`;
  const muted = `${markBase}/recall-mark-muted.png`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>A note from Avijit</title>
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
    .px { padding-left:30px !important; padding-right:30px !important; }
    .h1 { font-size:34px !important; line-height:1.08 !important; }
  }
</style>
</head>
<body style="margin:0; padding:0; background-color:#e7e5df;">

  <!-- preheader -->
  <span style="display:none; visibility:hidden; opacity:0; color:transparent; height:0; width:0; overflow:hidden; mso-hide:all;">A quick, personal hello from Avijit — the founder of Recall. Welcome in.</span>

  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#e7e5df;">
    <tr>
      <td align="center" style="padding:48px 16px 64px 16px;">

        <!-- brand lockup — mark hosted as a retina PNG so it renders in every client -->
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

        <!-- letter -->
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="container" style="width:600px; background-color:#fbfaf7; border-radius:26px;">
          <tr>
            <td class="px" style="padding:56px 60px 0 60px;">
              <div style="font-family:'Courier New',Courier,monospace; font-size:11px; letter-spacing:3px; text-transform:uppercase; color:#8A8780;">A note from the founder</div>
              <div class="h1" style="font-family:Georgia,'Times New Roman',serif; font-size:40px; line-height:1.06; letter-spacing:-0.4px; color:#111111; padding-top:20px;">Hey — welcome.<br>I'm really glad<br>you're here.</div>
            </td>
          </tr>

          <tr>
            <td class="px" style="padding:30px 60px 0 60px;">
              <p style="margin:0 0 18px 0; font-family:Georgia,'Times New Roman',serif; font-size:17px; line-height:1.72; color:#3a3833;">I'm Avijit. I build Recall — and I read every new sign-up, so I wanted to say hello properly.</p>

              <p style="margin:0 0 18px 0; font-family:Georgia,'Times New Roman',serif; font-size:17px; line-height:1.72; color:#3a3833;">Here's the thing that started it all: your brain forgets on a curve. Within a day, most of what you learn is <em>gone</em> — not because you're careless, but because forgetting is the default. Hermann Ebbinghaus mapped this in 1885, and it still holds.</p>

              <p style="margin:0 0 18px 0; font-family:Georgia,'Times New Roman',serif; font-size:17px; line-height:1.72; color:#3a3833;">But there's a lovely loophole. Revisit something <em>right</em> as it's about to slip, and the curve flattens — each review buys you exponentially more time. That's spaced repetition, and it's the quiet engine under everything Recall does.</p>

              <p style="margin:0; font-family:Georgia,'Times New Roman',serif; font-size:17px; line-height:1.72; color:#3a3833;">No streak guilt. No noise. Just a calm nudge at the right moment, so the things you care about actually stay. That's the whole promise.</p>
            </td>
          </tr>

          <!-- science pull-quote -->
          <tr>
            <td class="px" style="padding:34px 60px 0 60px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:22px 26px; background-color:#ffffff; border:1px solid #ece9e3; border-radius:18px;">
                    <div style="font-family:'Courier New',Courier,monospace; font-size:10.5px; letter-spacing:2.5px; text-transform:uppercase; color:#8A8780; padding-bottom:8px;">One number to keep</div>
                    <div style="font-family:Georgia,'Times New Roman',serif; font-size:16.5px; line-height:1.55; color:#111111;">Spacing your review instead of cramming can lift long-term recall by up to <strong>200%</strong> — same effort, remembered far longer.</div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- button -->
          <tr>
            <td class="px" style="padding:34px 60px 0 60px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="center" bgcolor="#111111" style="border-radius:16px;">
                    <a href="https://recall.app/start" target="_blank" style="display:block; padding:18px 40px; font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; color:#F7F6F3; border-radius:16px;">Add your first card&nbsp;&nbsp;&rarr;</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- signature -->
          <tr>
            <td class="px" style="padding:36px 60px 0 60px;">
              <div style="height:1px; background-color:#ece9e3; line-height:1px; font-size:1px;">&nbsp;</div>
              <p style="margin:24px 0 4px 0; font-family:Georgia,'Times New Roman',serif; font-size:17px; line-height:1.5; color:#3a3833;">Warmly,</p>
              <div style="font-family:Georgia,'Times New Roman',serif; font-style:italic; font-size:30px; color:#111111; line-height:1;">Avijit</div>
              <p style="margin:8px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:1.6; color:#8A8780;">Founder, Recall &nbsp;·&nbsp; Ripple Labs</p>
            </td>
          </tr>

          <tr>
            <td class="px" style="padding:22px 60px 56px 60px;">
              <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:14px; line-height:1.6; color:#5C5A55;">P.S. Reply straight to me at <a href="mailto:avijit@ripplelabs.in" class="lnk" style="color:#111111; text-decoration:underline;">avijit@ripplelabs.in</a> — tell me what you're trying to remember. I read them all.</p>
            </td>
          </tr>
        </table>

        <!-- footer -->
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
              <p style="margin:14px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; line-height:1.7; color:#a7a49d;">Recall by Ripple Labs<br>Made with &#128420; from India</p>
              <p style="margin:10px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; line-height:1.7; color:#a7a49d;">
                <a href="https://ripplelabs.in/recall/help" class="lnk" style="color:#8A8780; text-decoration:underline;">Help</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://ripplelabs.in/recall/privacy" class="lnk" style="color:#8A8780; text-decoration:underline;">Privacy</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://ripplelabs.in/recall/tos" class="lnk" style="color:#8A8780; text-decoration:underline;">Terms</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://recall.app/unsubscribe" class="lnk" style="color:#8A8780; text-decoration:underline;">Unsubscribe</a>
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

type Row = { user_id: string; email: string };

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("X-Cron-Secret") ?? "";
  if (!expected || !safeEqual(provided, expected)) {
    return new Response(
      JSON.stringify({ error: "unauthorized", message: "Invalid cron secret." }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const host = Deno.env.get("ZOHO_SMTP_HOST") ?? "smtppro.zoho.in";
  const port = Number(Deno.env.get("ZOHO_SMTP_PORT") ?? "587");
  const contactUser = Deno.env.get("ZOHO_CONTACT_USER") ?? "contact@ripplelabs.in";
  const contactPass = Deno.env.get("ZOHO_CONTACT_PASS") ?? "";
  const avijitUser = Deno.env.get("ZOHO_AVIJIT_USER") ?? "avijit@ripplelabs.in";
  const avijitPass = Deno.env.get("ZOHO_AVIJIT_PASS") ?? "";

  if (!supabaseUrl || !contactPass || !avijitPass) {
    console.error("onboarding-emails: missing SUPABASE_URL / ZOHO_*_PASS");
    return jsonResponse(
      { error: "provider_error", message: "server misconfigured" },
      503,
    );
  }

  const db = adminClient();
  const markBase = `${supabaseUrl}/storage/v1/object/public/brand-assets`;
  const nowIso = new Date().toISOString();

  let welcomed = 0;
  let foundered = 0;
  let failed = 0;

  // --- Welcome queue: instant on first confirm. ---
  const { data: welcomeRows, error: wErr } = await db
    .from("onboarding_emails")
    .select("user_id, email")
    .is("welcome_sent_at", null)
    .lt("welcome_attempts", MAX_ATTEMPTS)
    .limit(BATCH);
  if (wErr) {
    console.error("onboarding-emails: welcome select failed:", wErr.message);
    return jsonResponse({ error: "provider_error", message: wErr.message }, 503);
  }

  for (const row of (welcomeRows ?? []) as Row[]) {
    // Count the attempt before sending so a persistent failure can't loop forever.
    await db.rpc("bump_onboarding_attempt", {
      p_user_id: row.user_id,
      p_kind: "welcome",
    });
    try {
      await sendSmtp({
        host,
        port,
        user: contactUser,
        pass: contactPass,
        from: `Recall <${contactUser}>`,
        to: row.email,
        subject: WELCOME_SUBJECT,
        html: welcomeHtml(markBase),
      });
      await db
        .from("onboarding_emails")
        .update({ welcome_sent_at: new Date().toISOString(), last_error: null })
        .eq("user_id", row.user_id);
      welcomed++;
    } catch (err) {
      failed++;
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`onboarding-emails: welcome to ${row.email} failed:`, msg);
      await db
        .from("onboarding_emails")
        .update({ last_error: `welcome: ${msg}`.slice(0, 500) })
        .eq("user_id", row.user_id);
    }
  }

  // --- Founder queue: ~15 min after sign-up, only once welcome is out. ---
  const cutoff = new Date(Date.now() - FOUNDER_DELAY_MIN * 60_000).toISOString();
  const { data: founderRows, error: fErr } = await db
    .from("onboarding_emails")
    .select("user_id, email")
    .not("welcome_sent_at", "is", null)
    .is("founder_sent_at", null)
    .lt("founder_attempts", MAX_ATTEMPTS)
    .lte("signup_at", cutoff)
    .limit(BATCH);
  if (fErr) {
    console.error("onboarding-emails: founder select failed:", fErr.message);
    return jsonResponse({ welcomed, foundered, failed, error: fErr.message }, 200);
  }

  for (const row of (founderRows ?? []) as Row[]) {
    await db.rpc("bump_onboarding_attempt", {
      p_user_id: row.user_id,
      p_kind: "founder",
    });
    try {
      await sendSmtp({
        host,
        port,
        user: avijitUser,
        pass: avijitPass,
        from: `Avijit from Ripple Labs <${avijitUser}>`,
        replyTo: FOUNDER_REPLY_TO,
        to: row.email,
        subject: FOUNDER_SUBJECT,
        html: founderHtml(markBase),
      });
      await db
        .from("onboarding_emails")
        .update({ founder_sent_at: new Date().toISOString(), last_error: null })
        .eq("user_id", row.user_id);
      foundered++;
    } catch (err) {
      failed++;
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`onboarding-emails: founder to ${row.email} failed:`, msg);
      await db
        .from("onboarding_emails")
        .update({ last_error: `founder: ${msg}`.slice(0, 500) })
        .eq("user_id", row.user_id);
    }
  }

  return jsonResponse({ welcomed, foundered, failed });
});
