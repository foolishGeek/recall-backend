// FCM HTTP v1 sender for the compute-due Edge Function. Mints a short-lived
// OAuth2 access token from FCM_SERVICE_ACCOUNT_JSON (RS256 JWT, signed via Web
// Crypto) and posts a single notification+data message per device token.
// Secret: FCM_SERVICE_ACCOUNT_JSON (Firebase Admin SDK JSON) — S00 pre-flight.

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export interface FcmSendResult {
  ok: boolean;
  /** Token is permanently invalid (UNREGISTERED / bad token) — prune it. */
  prune: boolean;
}

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_URI = "https://oauth2.googleapis.com/token";

let cachedAccount: ServiceAccount | null = null;
let cachedToken: { value: string; expiresAt: number } | null = null;

function loadAccount(): ServiceAccount {
  if (cachedAccount) return cachedAccount;
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("FCM_SERVICE_ACCOUNT_JSON not set");
  const parsed = JSON.parse(raw) as ServiceAccount;
  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error("FCM_SERVICE_ACCOUNT_JSON missing required fields");
  }
  cachedAccount = parsed;
  return parsed;
}

export function fcmProjectId(): string {
  return loadAccount().project_id;
}

function base64url(bytes: Uint8Array): string {
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlJson(obj: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

function pemToBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function signJwt(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: account.client_email,
    scope: FCM_SCOPE,
    aud: TOKEN_URI,
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64urlJson(header)}.${base64urlJson(claims)}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  return `${unsigned}.${base64url(signature)}`;
}

/** Returns a cached OAuth2 access token, refreshing ~5 min before expiry. */
async function getAccessToken(): Promise<string> {
  const now = Date.now();
  if (cachedToken && cachedToken.expiresAt > now + 300_000) {
    return cachedToken.value;
  }

  const account = loadAccount();
  const assertion = await signJwt(account);
  const res = await fetch(TOKEN_URI, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    throw new Error(`FCM token exchange failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json() as { access_token: string; expires_in: number };
  cachedToken = {
    value: json.access_token,
    expiresAt: now + json.expires_in * 1000,
  };
  return cachedToken.value;
}

/**
 * Sends one Recall Drop to a single device token. Retries transient (5xx /
 * network) failures with a short backoff. Maps UNREGISTERED / 404 / invalid
 * token responses to { ok:false, prune:true } so the caller deletes the row.
 */
export async function sendDrop(
  token: string,
  data: Record<string, string>,
): Promise<FcmSendResult> {
  const accessToken = await getAccessToken();
  const projectId = fcmProjectId();
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const message = {
    message: {
      token,
      notification: {
        title: "Your cards are ready",
        body: "A fresh set is ready to review — tap to open Today.",
      },
      data,
      android: {
        priority: "HIGH",
        notification: {
          channel_id: "recall_drops",
          notification_priority: "PRIORITY_HIGH",
        },
      },
      apns: { headers: { "apns-priority": "10" } },
    },
  };

  let lastError = "";
  for (let attempt = 0; attempt < 3; attempt++) {
    let res: Response;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(message),
      });
    } catch (e) {
      lastError = String(e);
      await backoff(attempt);
      continue;
    }

    if (res.ok) return { ok: true, prune: false };

    const bodyText = await res.text();
    // 404 / UNREGISTERED / invalid token → permanent; prune the token.
    if (res.status === 404 || /UNREGISTERED|registration-token-not-registered/i.test(bodyText)) {
      return { ok: false, prune: true };
    }
    if (res.status === 400 && /INVALID_ARGUMENT/i.test(bodyText)) {
      return { ok: false, prune: true };
    }
    // 401/403 (auth) and 5xx are transient — retry; refresh token on auth fail.
    if (res.status === 401 || res.status === 403) {
      cachedToken = null;
    }
    lastError = `${res.status} ${bodyText}`;
    if (res.status < 500 && res.status !== 401 && res.status !== 403) {
      break;
    }
    await backoff(attempt);
  }

  console.error("FCM send failed (permanent):", lastError);
  return { ok: false, prune: false };
}

function backoff(attempt: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 200 * (attempt + 1)));
}
