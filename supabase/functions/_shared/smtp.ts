// Minimal STARTTLS SMTP client for Edge Functions (Deno can open outbound TCP).
// Extracted from the working auth-send-email sender so every function that needs
// to send branded mail (auth hook, onboarding emails) shares one battle-tested
// implementation. Sends a single text/html message; authenticates with AUTH LOGIN.

export interface SmtpMessage {
  host: string;
  port: number;
  /** Mailbox to authenticate as (also the default envelope sender). */
  user: string;
  pass: string;
  /** Header From, e.g. `Recall <contact@ripplelabs.in>`. */
  from: string;
  to: string;
  subject: string;
  html: string;
  /** Optional Reply-To header. */
  replyTo?: string;
  /** Envelope MAIL FROM; defaults to `user` (must be an address the host allows). */
  envelopeFrom?: string;
}

export async function sendSmtp(opts: SmtpMessage): Promise<void> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  const conn = await Deno.connect({ hostname: opts.host, port: opts.port });
  let sock: Deno.TcpConn | Deno.TlsConn = conn;
  let pending = "";
  const buf = new Uint8Array(4096);

  async function readReply(): Promise<string> {
    while (true) {
      // Complete SMTP reply: last line is "NNN <text>" (space, not hyphen).
      const lines = pending.split("\r\n").filter((l, i, a) =>
        l.length > 0 || i < a.length - 1
      );
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (/^\d{3} /.test(line)) {
          const consumed = lines.slice(0, i + 1).join("\r\n") + "\r\n";
          pending = pending.slice(consumed.length);
          return consumed;
        }
      }
      const n = await sock.read(buf);
      if (n === null) throw new Error("SMTP connection closed");
      pending += decoder.decode(buf.subarray(0, n));
    }
  }
  async function write(cmd: string): Promise<string> {
    await sock.write(encoder.encode(cmd + "\r\n"));
    return await readReply();
  }
  function expect(resp: string, code: string, step: string) {
    if (!resp.startsWith(code)) {
      throw new Error(`SMTP ${step} failed: ${resp.trim()}`);
    }
  }

  const envelopeFrom = opts.envelopeFrom ?? opts.user;
  const domain = (envelopeFrom.split("@")[1] ?? "recall.edge").trim();

  try {
    expect(await readReply(), "220", "banner");
    expect(await write("EHLO recall.edge"), "250", "EHLO");
    expect(await write("STARTTLS"), "220", "STARTTLS");
    sock = await Deno.startTls(conn, { hostname: opts.host });
    pending = "";
    expect(await write("EHLO recall.edge"), "250", "EHLO-TLS");
    expect(await write("AUTH LOGIN"), "334", "AUTH");
    expect(await write(btoa(opts.user)), "334", "USER");
    expect(await write(btoa(opts.pass)), "235", "PASS");
    expect(await write(`MAIL FROM:<${envelopeFrom}>`), "250", "MAIL FROM");
    expect(await write(`RCPT TO:<${opts.to}>`), "250", "RCPT TO");
    expect(await write("DATA"), "354", "DATA");

    const headerLines = [
      `From: ${opts.from}`,
      `To: ${opts.to}`,
      `Subject: ${opts.subject}`,
      `Date: ${new Date().toUTCString()}`,
      `Message-ID: <${crypto.randomUUID()}@${domain}>`,
    ];
    if (opts.replyTo) headerLines.push(`Reply-To: ${opts.replyTo}`);
    headerLines.push(
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=UTF-8",
      "Content-Transfer-Encoding: 8bit",
    );
    const headers = headerLines.join("\r\n");
    const body = opts.html.replace(/\r?\n/g, "\r\n").replace(/^\./gm, "..");
    // RFC 5322: a blank line (CRLF CRLF) separates headers from the body.
    // Without it, relays like Zoho that inject their own header (e.g.
    // X-ZohoMailClient) leak it into the rendered body.
    await sock.write(encoder.encode(headers + "\r\n\r\n" + body + "\r\n.\r\n"));
    expect(await readReply(), "250", "END");
    await write("QUIT").catch(() => {});
  } finally {
    try {
      sock.close();
    } catch {
      /* ignore */
    }
  }
}
