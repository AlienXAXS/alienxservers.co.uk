# Fake Minecraft server used to run a VLESS proxy over Cloudflare Tunnel

Incident writeup. A user of a free Minecraft server hosting tier replaced their
`server.jar` with a launcher that turns the allocated container into a
**VLESS proxy / VPN exit node**, reachable through a Cloudflare Tunnel.

Discovered 13 August 2026. Payload uploaded 12 August 2026.

All analysis below is **static** — nothing in the sample set was executed.

---

## Summary

| | |
|---|---|
| **Objective** | Free-hosting abuse: run a proxy exit node on someone else's infrastructure |
| **Disguise** | Fake `server.jar` printing forged Minecraft startup output |
| **Proxy** | sing-box 1.9.3 (VLESS + VLESS-Reality), renamed `audio-core` |
| **Transport** | cloudflared 2024.6.1 (named tunnel), renamed `bot-network` |
| **Not present** | No cryptominer, no credential theft, no persistence beyond the process |

The impact is that third-party proxy traffic egresses from the **host's** IP space:
abuse complaints, IP blacklisting and legal exposure all land on the provider.

---

## The chain

### 1. `server.jar` — the decoy

1,969 bytes. Contains a single `AppRunner.class` plus a manifest — a real Minecraft
server jar is tens of megabytes. It prints fake console output including a forged

```
[Server thread/INFO]: Done (1.234s)! For help, type "help"
```

so panel monitoring and log scrapers see a healthy server. It then, via `sh -c`:

1. Downloads portable Node.js v18.20.0 from `nodejs.org` if not already present
2. Unpacks it to `node-portable/`, `chmod +x`
3. Runs `npm install`, then `node index.js`

### 2. `index.js` — the loader

~54 KB, protected with obfuscator.io: shuffled string array, rotated-base64 string
encoding (lowercase-first alphabet), self-defending / anti-tamper stubs, and roughly
184 decoy entries padding the string table.

Recovered behaviour:

- Writes the sing-box `config.json` (the VLESS UUID, Reality private key, short_id and
  port values are all embedded in the loader as split string chunks)
- Downloads either binary if missing, from **official GitHub release URLs**:
  - `github.com/SagerNet/sing-box/releases/download/…/sing-box-1.9.3-linux-amd64.tar.gz`
  - `github.com/cloudflare/cloudflared/releases/download/…/cloudflared-linux-amd64`
- `chmodSync` + `renameSync` to innocuous names, then spawns both
- Runs cloudflared as `--token <embedded token>`
- Stands up a dummy HTTP server on the allocated port so health checks pass
- Registers an `uncaughtException` handler so it survives errors
- Emits fake log lines — `[System]`, `[Network]`, `starting network adapter`,
  `config generated` — and uses a spoofed `AppleWebKit` User-Agent for its downloads

The decoy `package.json` declares the project as `discord-music-bot`, which is where the
binary names `audio-core` and `bot-network` come from.

### 3. The binaries

Both are **unmodified official upstream builds**, confirmed from Go build metadata
(main module path plus VCS revision), not custom or backdoored forks:

| File | Actually | Module | VCS revision | Built |
|---|---|---|---|---|
| `audio-core` | sing-box 1.9.3 | `github.com/sagernet/sing-box` | `085f60337799afc906069b540a38368968c123e4` | 2024-06-09 |
| `bot-network` | cloudflared 2024.6.1 | `github.com/cloudflare/cloudflared` | `628176a2d64c723f637a1877a109d1c9c779df21` | 2024-06-17 |

### 4. `config.json` — the proxy configuration

Two VLESS inbounds:

- **`vless-in`** — WebSocket on `127.0.0.1:1234`. This is the tunnel's origin: cloudflared
  connects here, so the proxy needs no inbound port of its own.
- **`vless-reality-in`** — VLESS-Reality on `[::]:10016`, forging its TLS handshake as
  `itunes.apple.com` to survive protocol inspection.

The Cloudflare Tunnel is the load-bearing part of the design. The hosting platform allocates
one game port per customer (`15003` here), so the tunnel is the operator's only route to the
proxy — and it survives any inbound firewalling the provider applies.

---

## Recovering the tunnel token

The embedded cloudflared token identifies the account behind this, so it was worth extracting.
It could not be read directly: obfuscator.io splits long literals into 10-character chunks and
stores them shuffled, some plaintext and some base64-encoded, with read order determined by
index arithmetic against a table rotated at runtime. Resolving that order normally means
running the sample.

[`recover_cf_token.py`](recover_cf_token.py) recovers it **without executing anything**, by
reconstructing the order from content instead. The token decodes to

```
{"a":"<32 hex>","t":"<uuid>","s":"<base64 secret>"}
```

so every partial concatenation must still base64-decode to a valid prefix of that template.
That constraint prunes the search to a handful of candidates.

Two validation lessons, both of which produced confidently wrong output first time:

1. **Check structure, not character classes.** Accepting "36 characters of hex-and-dashes"
   for the tunnel ID let a shuffled ordering pass as valid. Enforcing real UUIDv4 layout —
   8-4-4-4-12, version nibble, variant nibble — eliminated it.
2. **Check nested encodings.** The final 32 candidates differed only in the ordering of the
   secret's chunks. The secret is *itself* base64; exactly one candidate decoded to clean
   ASCII (a UUID), and the rest to binary garbage.

Recovered identifiers — the secret is withheld from this public writeup and was supplied to
Cloudflare separately:

| Field | Value |
|---|---|
| Account tag | `7aa9cfa1d05b8f026876074d06a1b918` |
| Tunnel ID | `70d62716-4a3d-4471-81a0-788fa61cbbef` |

The tunnel's **ingress hostnames are not recoverable from the sample set** — cloudflared
fetches its ingress configuration from Cloudflare's API at runtime, so nothing on disk records
what was routed through it.

---

## Detection notes for other hosts

Ranked by signal quality, from a provider's perspective:

| Signal | False positives | Catches this |
|---|---|---|
| ELF binaries anywhere in a Java server's volume | ~none | yes |
| Listening socket on a port outside the server's allocations | ~none | yes — 1234/10016 vs allocated 15003 |
| Long-lived non-`java` process in the container | very low | yes — `node`, `curl` |
| `server.jar` under ~1 MB, or a jar with no `net/minecraft`, `plugin.yml`, `fabric.mod.json`, `META-INF/mods.toml` or `bungee.yml` | low | yes — 1,969 bytes |
| Any binary file overwritten | **high** — users upload plugin and mod jars constantly | yes, but unusably noisy |

**Upload-time detection alone is not sufficient.** The Node.js runtime here is fetched at
*runtime* by the jar, so it generates no upload event. Detection needs a periodic on-disk
scan and egress/process visibility as well.

Two controls make detection largely unnecessary for this class of abuse:

- **Mount the server volume `noexec`.** The downloaded `node` binary then cannot execute and
  the chain dies at step one. For Java-only eggs nothing legitimate breaks, since the JVM
  lives in the image rather than the volume. Verify against any non-Java game images first.
- **Default-deny egress with a small allowlist.** A Minecraft server needs session/auth
  endpoints and perhaps a plugin repository. It does not need `nodejs.org`, arbitrary release
  CDNs, or persistent QUIC to Cloudflare's edge.

---

## Contents of this repository

| Path | |
|---|---|
| `README.md` | This writeup |
| `IOCS.md` | Indicators of compromise, hashes, detection strings |
| `cloudflare-abuse-report.md` | The abuse report submitted to Cloudflare |
| `recover_cf_token.py` | Static token reconstruction tool |
| `samples/config.json` | The sing-box configuration written by the loader |

**Deliberately not included:** `server.jar`, `index.js`, and the two binaries.

The loader is excluded for a specific reason beyond the usual reluctance to publish malware —
`index.js` contains the tunnel token in recoverable form, so publishing it would publish a
live credential. Full samples are available to researchers and to affected providers on
request; hashes are in `IOCS.md`.

---

## Timeline

| When | What |
|---|---|
| 2024-06-09 / 2024-06-17 | Build dates of the bundled sing-box and cloudflared binaries |
| 2026-08-12 | Payload uploaded; loader, config and cloudflared written to the volume |
| 2026-08-13 | Discovered, samples preserved, static analysis performed |
| 2026-08-13 | Tunnel token recovered; abuse report filed with Cloudflare |
