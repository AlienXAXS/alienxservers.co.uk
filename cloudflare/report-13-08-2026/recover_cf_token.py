#!/usr/bin/env python3
"""
recover_cf_token.py

Reconstruct the Cloudflare Tunnel token embedded in an obfuscator.io-protected
JavaScript file, without executing any part of the sample.

The sample is only ever read as TEXT. Nothing from it is imported, eval'd or run.

How it works
------------
obfuscator.io splits long string literals into fixed-size chunks (10 chars here)
and stores them in a shuffled array. Some chunks are stored as plaintext, others
base64-encoded with a rotated alphabet (lowercase first). The concatenation order
lives in the code as index arithmetic against a runtime-rotated array -- resolving
that would mean executing the sample, so instead we recover the order by content:

A cloudflared token is base64 of
    {"a":"<32 hex>","t":"<uuid>","s":"<base64 secret>"}

so every partial concatenation must still base64-decode to a valid PREFIX of that
template. That constraint is strong enough to collapse the search to one path.

Usage
-----
    python recover_cf_token.py index.js
    python recover_cf_token.py index.js --lax          # looser validation
    python recover_cf_token.py index.js --chunk 10     # chunk size override

Run it on an offline box. It makes no network calls and writes no files.
"""

import argparse
import base64
import json
import re
import sys

# obfuscator.io's rotated alphabet: lowercase first, then uppercase, digits, +/=
CUSTOM_B64 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/="
STD_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
ROT_TO_STD = str.maketrans(CUSTOM_B64, STD_B64)
URLSAFE_TO_STD = str.maketrans("-_", "+/")

TOKEN_ALPHABET = set(STD_B64) | set("-_")

# Structure of the decoded token, used as the search constraint.
HEX = "0123456789abcdef"


def _uuid_classes(strict_v4=True):
    """
    Per-position character classes for a v4 UUID: 8-4-4-4-12, version nibble '4'
    at index 14, variant nibble in [89ab] at index 19.

    Checking only "36 chars of hex-or-dash" is far too loose: it lets the search
    close out on a shuffled chunk ordering that happens to be hex all the way
    through, which is exactly how you get a tunnel id like 471-81a0-788fa...
    """
    cls = []
    for i in range(36):
        if i in (8, 13, 18, 23):
            cls.append("-")
        elif i == 14 and strict_v4:
            cls.append("4")
        elif i == 19 and strict_v4:
            cls.append("89ab")
        else:
            cls.append(HEX)
    return cls


# base64 of 32 random bytes is 44 chars. A 3-char "secret" is a failed assembly.
MIN_SECRET = 40

SEGMENTS = [
    ("lit", '{"a":"'),
    ("cls", 32, HEX),
    ("lit", '","t":"'),
    ("pos", _uuid_classes()),
    ("lit", '","s":"'),
    ("var", "".join(sorted(TOKEN_ALPHABET))),
    ("lit", '"}'),
]


def rot_b64_decode(s):
    """Decode one string-array entry using the rotated alphabet. None on failure."""
    t = s.translate(ROT_TO_STD)
    t += "=" * (-len(t) % 4)
    try:
        return base64.b64decode(t, validate=False)
    except Exception:
        return None


def b64_decode_token(s):
    """Decode a (possibly url-safe, possibly unpadded) token fragment."""
    t = s.translate(URLSAFE_TO_STD)
    t += "=" * (-len(t) % 4)
    return base64.b64decode(t, validate=True)


def walk_template(text):
    """
    Check `text` against the token template.
    Returns (is_valid_prefix, is_complete).
    """
    i = 0
    for seg in SEGMENTS:
        if seg[0] == "lit":
            for ch in seg[1]:
                if i == len(text):
                    return True, False
                if text[i] != ch:
                    return False, False
                i += 1
        elif seg[0] == "cls":
            for _ in range(seg[1]):
                if i == len(text):
                    return True, False
                if text[i] not in seg[2]:
                    return False, False
                i += 1
        elif seg[0] == "pos":
            for allowed in seg[1]:
                if i == len(text):
                    return True, False
                if text[i] not in allowed:
                    return False, False
                i += 1
        else:  # variable-length base64 run, terminated by the closing quote
            start = i
            while i < len(text) and text[i] in seg[1]:
                i += 1
            if i == len(text):
                return True, False
            if i - start < MIN_SECRET:      # quote closed far too early
                return False, False
    return i == len(text), i == len(text)


def walk_lax(text):
    """Fallback validator: printable ASCII made of plausible JSON/base64 chars."""
    ok = all(c in TOKEN_ALPHABET or c in '{}":,' for c in text)
    return ok, text.startswith('{"') and text.endswith('"}')


def feasible(token, validator):
    """Is `token` a viable prefix of the real token?"""
    n = len(token) - len(token) % 4
    if n == 0:
        return True
    try:
        raw = b64_decode_token(token[:n])
        text = raw.decode("ascii")
    except Exception:
        return False
    return validator(text)[0]


def complete(token, validator):
    """If `token` decodes to a whole, well-formed token, return its parsed JSON."""
    try:
        text = b64_decode_token(token).decode("ascii")
    except Exception:
        return None
    if not validator(text)[1]:
        return None
    try:
        obj = json.loads(text)
    except Exception:
        return None
    if not {"a", "t", "s"} <= set(obj):
        return None
    if not re.fullmatch(r"[0-9a-f]{32}", obj["a"]):
        return None
    if not re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", obj["t"]
    ):
        return None
    if len(obj["s"]) < MIN_SECRET:
        return None
    try:                                    # the secret must be real base64
        if len(base64.b64decode(obj["s"] + "=" * (-len(obj["s"]) % 4))) < 24:
            return None
    except Exception:
        return None
    return obj


def harvest(path, chunk_len):
    """Pull every plausible token chunk out of the file, plaintext and encoded."""
    src = open(path, "r", encoding="utf-8", errors="replace").read()
    entries = set(re.findall(r"'([A-Za-z0-9+/=_-]{2,})'", src))

    full, tail = set(), set()
    for entry in entries:
        cands = []
        if set(entry) <= TOKEN_ALPHABET:
            cands.append(entry)                       # stored as plaintext
        raw = rot_b64_decode(entry)
        if raw is not None:
            try:
                dec = raw.decode("ascii")
                if dec and set(dec) <= TOKEN_ALPHABET:
                    cands.append(dec)                 # stored base64-encoded
            except UnicodeDecodeError:
                pass
        for c in cands:
            if len(c) == chunk_len:
                full.add(c)
            elif 0 < len(c) < chunk_len:
                tail.add(c)                           # only valid as last chunk
    return sorted(full), sorted(tail)


def solve(full, tail, validator, max_len, node_cap, max_solutions=32):
    """
    Depth-first reassembly with prefix pruning.

    Collects EVERY assembly that satisfies the constraints rather than returning
    the first -- stopping at the first hit is what produced a 3-char secret, since
    the shortest closing assembly is found long before the correct one.

    Returns (solutions, best_partial).
    """
    best_partial = ""
    nodes = 0
    solutions = []

    def dfs(prefix, used):
        nonlocal best_partial, nodes
        if len(solutions) >= max_solutions or nodes > node_cap:
            return
        nodes += 1
        if len(prefix) > len(best_partial):
            best_partial = prefix

        obj = complete(prefix, validator)
        if obj:
            solutions.append((prefix, obj, len(used)))
            return                                    # nothing extends a closed token

        for t in tail:                                # try to close it out
            obj = complete(prefix + t, validator)
            if obj:
                solutions.append((prefix + t, obj, len(used) + 1))

        if len(prefix) >= max_len:
            return
        for i, c in enumerate(full):
            if i in used:
                continue
            cand = prefix + c
            if feasible(cand, validator):
                dfs(cand, used | {i})

    seeds = [i for i, c in enumerate(full) if c.startswith("eyJ")] or list(range(len(full)))
    for i in seeds:
        if feasible(full[i], validator):
            dfs(full[i], {i})

    solutions.sort(key=lambda s: -s[2])                # most chunks consumed first
    return solutions, best_partial


def main():
    global MIN_SECRET
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="obfuscated .js file (read as text only)")
    ap.add_argument("--chunk", type=int, default=10, help="split chunk size (default 10)")
    ap.add_argument("--lax", action="store_true", help="relax structural validation")
    ap.add_argument("--max-len", type=int, default=400, help="max token length to try")
    ap.add_argument("--nodes", type=int, default=2_000_000, help="search node cap")
    ap.add_argument("--min-secret", type=int, default=MIN_SECRET,
                    help="reject assemblies whose secret is shorter than this")
    ap.add_argument("--any-uuid", action="store_true",
                    help="drop the v4 version/variant nibble checks on the tunnel id")
    args = ap.parse_args()

    MIN_SECRET = args.min_secret
    if args.any_uuid:
        SEGMENTS[3] = ("pos", _uuid_classes(strict_v4=False))

    validator = walk_lax if args.lax else walk_template
    full, tail = harvest(args.path, args.chunk)
    print(f"[*] {len(full)} full chunks ({args.chunk} chars), {len(tail)} tail chunks")
    seeds = [c for c in full if c.startswith("eyJ")]
    print(f"[*] seed candidates: {seeds or 'none - will brute-force every start'}")

    solutions, partial = solve(full, tail, validator, args.max_len, args.nodes)

    if solutions:
        print(f"\n[+] {len(solutions)} assembly/assemblies satisfy the constraints "
              f"(most chunks consumed first)")
        for token, obj, nchunks in solutions[:5]:
            print(f"\n--- {nchunks} chunks, {len(token)} chars ---")
            print(token)
            print(f"    account tag : {obj['a']}")
            print(f"    tunnel id   : {obj['t']}")
            print(f"    secret      : {obj['s']}  ({len(obj['s'])} chars)")
        if len(solutions) > 1:
            print("\n[!] more than one assembly fits -- these are candidates, not")
            print("    the answer. Sanity-check the tunnel id shape before acting.")
        print("\n    A live credential. Report to Cloudflare abuse privately;")
        print("    do not publish it and do not run cloudflared with it.")
        return 0

    print("\n[-] no complete token assembled.")
    if partial:
        print(f"[*] longest consistent prefix ({len(partial)} chars):\n    {partial}")
        n = len(partial) - len(partial) % 4
        if n:
            try:
                print("[*] which decodes to:")
                print("    " + b64_decode_token(partial[:n]).decode("ascii"))
                print("\n    Even a partial usually exposes the account tag and tunnel")
                print("    UUID, which is enough to file a Cloudflare abuse report.")
            except Exception:
                pass
    print("\n[*] if this stalls, try: --lax, or --chunk with a different size")
    return 1


if __name__ == "__main__":
    sys.exit(main())
