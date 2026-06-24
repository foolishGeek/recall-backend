// SSRF guard for outbound fetches (link-preview). Rejects hosts that resolve to
// private / loopback / link-local / cloud-metadata addresses. Public hosts pass.

function ipv4ToInt(ip: string): number | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    const v = Number(p);
    if (!Number.isInteger(v) || v < 0 || v > 255) return null;
    n = (n << 8) | v;
  }
  return n >>> 0;
}

function inV4Cidr(ip: number, base: string, bits: number): boolean {
  const b = ipv4ToInt(base);
  if (b == null) return false;
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (ip & mask) === (b & mask);
}

export function isPrivateIpv4(ip: string): boolean {
  const n = ipv4ToInt(ip);
  if (n == null) return true; // unparseable → treat as unsafe
  return (
    inV4Cidr(n, "0.0.0.0", 8) ||
    inV4Cidr(n, "10.0.0.0", 8) ||
    inV4Cidr(n, "100.64.0.0", 10) ||
    inV4Cidr(n, "127.0.0.0", 8) ||
    inV4Cidr(n, "169.254.0.0", 16) || // link-local incl. 169.254.169.254 metadata
    inV4Cidr(n, "172.16.0.0", 12) ||
    inV4Cidr(n, "192.0.0.0", 24) ||
    inV4Cidr(n, "192.168.0.0", 16) ||
    inV4Cidr(n, "198.18.0.0", 15) ||
    inV4Cidr(n, "224.0.0.0", 4) ||
    inV4Cidr(n, "240.0.0.0", 4)
  );
}

export function isPrivateIpv6(ip: string): boolean {
  const lower = ip.toLowerCase();
  if (lower === "::1" || lower === "::") return true;
  if (lower.startsWith("fe80") || lower.startsWith("fc") || lower.startsWith("fd")) return true;
  // IPv4-mapped (::ffff:a.b.c.d) → check the embedded v4.
  const mapped = lower.match(/::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPrivateIpv4(mapped[1]);
  return false;
}

/** Resolves the host and returns true if every resolved address is public. */
export async function isHostPublic(hostname: string): Promise<boolean> {
  const h = hostname.toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".internal")) return false;

  // IP literals: validate directly without DNS.
  if (/^\d+\.\d+\.\d+\.\d+$/.test(h)) return !isPrivateIpv4(h);
  if (h.includes(":")) return !isPrivateIpv6(h);

  let any = false;
  for (const kind of ["A", "AAAA"] as const) {
    try {
      const addrs = await Deno.resolveDns(hostname, kind);
      for (const a of addrs) {
        any = true;
        if (kind === "A" ? isPrivateIpv4(a) : isPrivateIpv6(a)) return false;
      }
    } catch {
      // no record for this kind — keep checking the other
    }
  }
  return any; // public only if it resolved to at least one (public) address
}
