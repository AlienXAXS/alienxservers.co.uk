# Cloudflare abuse report — draft

**Send to:** https://www.cloudflare.com/abuse/ (category: *Phishing & Malware* → "other abuse")
or `abuse@cloudflare.com` if you prefer email. The web form gets a ticket number; email
sometimes doesn't.

---

**Subject:** Abuse report — Cloudflare Tunnel used to proxy traffic from compromised hosting (Tunnel ID 70d62716-4a3d-4471-81a0-788fa61cbbef)

Hello,

I operate [COMPANY], a Minecraft server hosting provider. On 13 August 2026 we found that a
user of our free hosting tier had replaced their game server with proxy software, using a
Cloudflare Tunnel to expose it. I'm reporting the tunnel and the account behind it.

**Cloudflare identifiers**

| Field | Value |
|---|---|
| Account tag | `7aa9cfa1d05b8f026876074d06a1b918` |
| Tunnel ID | `70d62716-4a3d-4471-81a0-788fa61cbbef` |
| Client | cloudflared 2024.6.1 (official build, renamed to `bot-network`) |
| First seen | 12 August 2026 |

We recovered a full, valid tunnel token (account tag, tunnel ID and secret) from the
attacker's own loader script. I have not connected to the tunnel and will not. The complete
token is available to your team on request — I've left the secret out of this email rather
than transmit it in plaintext.

**What was deployed**

The user uploaded a 1,969-byte `server.jar` that is not a Minecraft server. It prints forged
Minecraft startup output to defeat our monitoring, then downloads a portable Node.js runtime
and runs an obfuscated loader. That loader deploys two renamed binaries — both unmodified
official builds:

- `audio-core` — sing-box 1.9.3, configured with two VLESS inbounds: a WebSocket listener on
  `127.0.0.1:1234` (the tunnel's origin) and a VLESS-Reality listener that forges its TLS
  handshake as `itunes.apple.com`
- `bot-network` — cloudflared 2024.6.1, run as `--token <token>` against the tunnel above

The Cloudflare Tunnel is what makes this work: our platform allocates each customer a single
game port, so the tunnel is the operator's only path to reach the proxy. Traffic from
unknown third parties egresses from our IP space.

**What I'm asking for**

1. Investigate and terminate tunnel `70d62716-4a3d-4471-81a0-788fa61cbbef` and review the
   account it belongs to for related tunnels.
2. If you're able to share it, the ingress hostname(s) configured for this tunnel. cloudflared
   fetches its ingress config from your API at runtime, so that configuration is not present
   in any file we recovered — we have no visibility into what hostnames were routed here.

**Evidence retained**

Full sample set preserved, unmodified, available on request:

| File | SHA-256 |
|---|---|
| `server.jar` | `6d41b52b0548b4a62a0265c954c74d05c8a9872d88197397ccd9bb4332f31990` |
| `index.js` (loader) | `66291352acef8165c367de620875b8334209b2b8b89682851c844d050b70ee57` |
| `audio-core` (sing-box) | `557dbf51f90417d680b8398d99ac4d7ed4eb320de02c9837f938cf3294fb927d` |
| `bot-network` (cloudflared) | `a0f271b8ffb464cc58a8e8f81915049aabd399cc66a2a8c70cc4348bc8f44c8f` |

Also retained: the generated sing-box `config.json` (VLESS UUID
`2c11bde0-fa06-4438-9ff0-f8502faf6aa3`, Reality short_id `d251bcb464734a18`), the account
registration details and source IPs for the user who uploaded it, and our upload logs.

Happy to provide any of the above, including the full token, to your abuse or trust & safety
team through whatever channel you prefer.

Regards,
[NAME]
[ROLE], [COMPANY]
[EMAIL] · [PHONE]
