#!/usr/bin/env python3
"""12 recovery words -> AGE-SECRET-KEY-1... for the stock age CLI. Standard library only.

    python3 words-to-age-key.py лючок факт брифинг ... > key.txt
    age -d -i key.txt document.age > document

The archive can be opened without Редакция: this script, the word list next to it and age
(https://age-encryption.org) are enough. The scheme is in spec/archive-format.md.
"""
import hashlib
import hmac
import os
import sys

WORDS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "recovery-words-ru.txt")
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def hkdf_sha256(ikm, salt, info, length=32):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block, i = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out += block
        i += 1
    return out[:length]


def bech32(hrp, data):
    acc, bits, values = 0, 0, []
    for byte in data:
        acc = (acc << 8) | byte
        bits += 8
        while bits >= 5:
            bits -= 5
            values.append((acc >> bits) & 31)
    if bits:
        values.append((acc << (5 - bits)) & 31)
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp] + values + [0] * 6:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            if (top >> i) & 1:
                chk ^= gen[i]
    chk ^= 1
    return hrp + "1" + "".join(CHARSET[v] for v in values + [(chk >> 5 * (5 - i)) & 31 for i in range(6)])


def main(words):
    with open(WORDS, encoding="utf-8") as f:
        wordlist = [w.strip() for w in f if w.strip()]
    if len(wordlist) != 2048:
        sys.exit("word list must have 2048 words")
    if len(words) != 12:
        sys.exit("need 12 words")
    bits = ""
    for word in words:
        w = word.lower().replace("ё", "е")
        found = [i for i, x in enumerate(wordlist) if x == w or (len(w) >= 4 and x.startswith(w))]
        if len(found) != 1:
            sys.exit(f"unknown word: {word}")
        bits += f"{found[0]:011b}"
    entropy = int(bits[:128], 2).to_bytes(16, "big")
    if int(bits[128:], 2) != hashlib.sha256(entropy).digest()[0] >> 4:
        sys.exit("checksum mismatch: a word is wrong or out of order")
    key = hkdf_sha256(entropy, b"redakciya/recovery/v1", b"age-x25519")
    print(bech32("age-secret-key-", key).upper())


if __name__ == "__main__":
    main(sys.argv[1:])
