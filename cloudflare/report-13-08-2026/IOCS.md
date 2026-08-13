# Indicators of compromise

Fake Minecraft `server.jar` → Node.js loader → sing-box VLESS proxy over Cloudflare Tunnel.
Observed 12–13 August 2026 on free Minecraft server hosting.

## File hashes (SHA-256)

| File | SHA-256 | Notes |
|---|---|---|
| `server.jar` | `6d41b52b0548b4a62a0265c954c74d05c8a9872d88197397ccd9bb4332f31990` | 1,969 bytes; single `AppRunner.class` |
| `AppRunner.java` | `9f40d9ac1ef70aa6705052dc44ba54dbde8861da927fb64ac89d54cce50566ae` | Decompiled from the above |
| `index.js` | `66291352acef8165c367de620875b8334209b2b8b89682851c844d050b70ee57` | obfuscator.io loader; contains the tunnel token |
| `config.json` | `ffa2b19cd4907add20ccfad7d161c773fd6a24c0936c25c063b81c1c22fa0cdb` | Generated sing-box config |
| `audio-core` | `557dbf51f90417d680b8398d99ac4d7ed4eb320de02c9837f938cf3294fb927d` | sing-box 1.9.3, stock upstream build |
| `bot-network` | `a0f271b8ffb464cc58a8e8f81915049aabd399cc66a2a8c70cc4348bc8f44c8f` | cloudflared 2024.6.1, stock upstream build |

The two binaries are unmodified official releases — their hashes identify *this bundle*, not
malicious code. Do not use them as standalone malware indicators.

## Network

| Indicator | Value |
|---|---|
| Cloudflare account tag | `7aa9cfa1d05b8f026876074d06a1b918` |
| Cloudflare Tunnel ID | `70d62716-4a3d-4471-81a0-788fa61cbbef` |
| Tunnel address | `70d62716-4a3d-4471-81a0-788fa61cbbef.cfargotunnel.com` |
| Reality SNI / handshake target | `itunes.apple.com:443` |
| Download source (Node.js) | `https://nodejs.org/dist/v18.20.0/node-v18.20.0-linux-x64.tar.gz` |
| Download source (proxy) | `https://github.com/SagerNet/sing-box/releases/download/…/sing-box-1.9.3-linux-amd64.tar.gz` |
| Download source (tunnel) | `https://github.com/cloudflare/cloudflared/releases/download/…/cloudflared-linux-amd64` |

Ingress hostnames for the tunnel are **not recoverable** from the sample set; cloudflared
fetches them from Cloudflare's API at runtime.

## Proxy configuration

| Indicator | Value |
|---|---|
| VLESS UUID | `2c11bde0-fa06-4438-9ff0-f8502faf6aa3` |
| Reality private key | `WM8nHADnPUrHzFDDyPv2GpKk9BxOAt_7JhdtpgPjGkc` |
| Reality short_id | `d251bcb464734a18` |
| Inbound (tunnel origin) | `127.0.0.1:1234`, VLESS over WebSocket, path `/` |
| Inbound (direct) | `[::]:10016`, VLESS-Reality, flow `xtls-rprx-vision` |
| Allocated game port | `15003` — note neither inbound uses it |

## Filesystem

```
server.jar          # < 5 KB, not a real server jar
index.js            # obfuscated loader
config.json         # sing-box config, adjacent to a "Minecraft" server
package.json        # declares "discord-music-bot"
audio-core          # ELF, ~29 MB
bot-network         # ELF, ~37 MB
node-portable/      # portable Node.js runtime, fetched at runtime
node.tar.gz         # transient, deleted after extraction
```

## Host behaviour

- Non-`java` long-lived processes in a Minecraft container: `node`, `curl`, `tar`
- Listening sockets on ports outside the server's allocation
- ELF executables written into a Java server's volume
- Outbound to `nodejs.org` and GitHub release CDNs from a game server
- Sustained outbound QUIC/443 to Cloudflare edge ranges
- Forged console line `[Server thread/INFO]: Done (1.234s)! For help, type "help"` —
  the fixed `1.234s` timing is a reliable tell, since real startup times vary

## Loader strings

Present in `index.js` as split, partly base64-encoded chunks; useful for YARA-style matching
once decoded. The encoding is base64 with a rotated alphabet:
`abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=`

```
[System]        [Network]       network adapter
starting au…    starting ne…    config gene…
audio-core      sing-box        cloudflared
--token         -linux-amd64    .tar.gz
```
