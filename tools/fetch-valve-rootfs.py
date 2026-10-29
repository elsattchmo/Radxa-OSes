#!/usr/bin/env python3
"""Download and verify Valve's SteamOS (Steam Frame, aarch64 "vr") root filesystem.

    fetch-valve-rootfs.py [--channel stable|rc] [--out DIR] [--jobs N]

Steps:
  1. Read Valve's update manifest for the channel (steamdeck-atomupd.steamos.cloud).
  2. Download the RAUC bundle (~2 MB) and check its CMS signature. The signer's
     public key is pinned below; a different key stops the download unless
     --accept-new-signer is given.
  3. Rebuild rootfs.img (~10 GB, sparse) from Valve's casync chunk stores,
     checking every chunk's SHA-512/256 digest.
  4. Check the finished image against the sha256 in the signed bundle manifest.

The download resumes if interrupted: run the same command again.
Needs: python3, python3-zstandard, openssl, unsquashfs (squashfs-tools).
Nothing from Valve is redistributed: everything is fetched from Valve's servers.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

META_URL = "https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/{channel}.json"
IMAGES_URL = "https://steamdeck-images.steamos.cloud/"
# sha256 of the DER public key of Valve's bundle signer (CN=frame-images, issued by
# CN=steamdeck-images, valid 2026-02-05 to 2126-01-12). Recorded 2026-10-29.
SIGNER_PUBKEY_SHA256 = "0d277be574a0827aca8afc515bef4f382c87f9e296df5310d63601167b632096"
EXPECTED_COMPATIBLE = "steamos-aarch64"

CA_FORMAT_INDEX = 0x96824D9C7B129FF9
CA_FORMAT_TABLE = 0xE75B9E112F17417D
CA_FORMAT_SHA512_256 = 0x2000000000000000
USER_AGENT = "radxa-oses-fetch/1"


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def die(msg: str) -> "None":
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def http_get(url: str, timeout: int = 60, attempts: int = 6) -> bytes:
    delay = 2
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise
            err = e
        except Exception as e:  # network hiccup: retry
            err = e
        if i < attempts - 1:
            time.sleep(delay)
            delay = min(delay * 2, 30)
    raise RuntimeError(f"{url}: {err}")


def read_manifest(channel: str) -> dict:
    data = json.loads(http_get(META_URL.format(channel=channel)))
    cands = data.get("minor", {}).get("candidates") or data.get("major", {}).get("candidates") or []
    if not cands:
        die(f"no update candidate in the {channel} manifest")
    return cands[0]


def split_bundle(path: str, workdir: str) -> tuple[str, str]:
    """A RAUC 'plain' bundle is squashfs + CMS signature + 8-byte big-endian signature size."""
    with open(path, "rb") as f:
        f.seek(-8, os.SEEK_END)
        total = f.tell() + 8
        (sig_size,) = struct.unpack(">Q", f.read(8))
        if not 0 < sig_size < total:
            die("bundle has no valid signature trailer")
        payload_size = total - 8 - sig_size
        f.seek(payload_size)
        sig = f.read(sig_size)
    sig_path = os.path.join(workdir, "bundle.sig.der")
    with open(sig_path, "wb") as f:
        f.write(sig)
    payload_path = os.path.join(workdir, "bundle.sqfs")
    with open(path, "rb") as src, open(payload_path, "wb") as dst:
        remaining = payload_size
        while remaining:
            chunk = src.read(min(remaining, 1 << 20))
            dst.write(chunk)
            remaining -= len(chunk)
    return sig_path, payload_path


def verify_bundle(sig_path: str, payload_path: str, workdir: str, accept_new: bool, bundle: str = "") -> dict:
    r = subprocess.run(["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", sig_path,
                        "-content", payload_path, "-noverify", "-out", os.devnull],
                       capture_output=True, text=True)
    if r.returncode != 0:
        if bundle:
            os.remove(bundle)  # corrupt download: fetch it again next time
        die("bundle signature does not match its contents (the download was deleted; run again):\n"
            + r.stderr.strip())
    certs = subprocess.run(["openssl", "pkcs7", "-inform", "DER", "-in", sig_path, "-print_certs"],
                           capture_output=True, text=True, check=True).stdout
    pem = os.path.join(workdir, "signer.pem")
    with open(pem, "w") as f:
        f.write(certs)
    subject = subprocess.run(["openssl", "x509", "-in", pem, "-noout", "-subject", "-issuer"],
                             capture_output=True, text=True, check=True).stdout.strip()
    pub = subprocess.run(["openssl", "x509", "-in", pem, "-noout", "-pubkey"],
                         capture_output=True, check=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=pub,
                         capture_output=True, check=True).stdout
    fp = hashlib.sha256(der).hexdigest()
    if fp != SIGNER_PUBKEY_SHA256:
        msg = (f"bundle signer key changed (got {fp}, pinned {SIGNER_PUBKEY_SHA256}).\n{subject}\n"
               "Valve may have rotated keys; check before trusting it.")
        if not accept_new:
            die(msg + "\nRe-run with --accept-new-signer to continue anyway.")
        print("WARNING: " + msg, file=sys.stderr)
    return {"signer": subject, "signer_pubkey_sha256": fp, "signer_pinned": fp == SIGNER_PUBKEY_SHA256}


def parse_raucm(text: str) -> dict:
    out, section = {}, ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif "=" in line:
            k, v = line.split("=", 1)
            out[f"{section}.{k}"] = v
    return out


def parse_caibx(path: str) -> tuple[int, int, list[tuple[int, int, bytes]]]:
    with open(path, "rb") as f:
        data = f.read()
    size, magic, flags, _mn, _avg, max_sz = struct.unpack_from("<6Q", data, 0)
    if magic != CA_FORMAT_INDEX or size != 48:
        die("rootfs.img.caibx is not a casync index")
    _tsize, tmagic = struct.unpack_from("<2Q", data, 48)
    if tmagic != CA_FORMAT_TABLE:
        die("casync index has no chunk table")
    body = data[64:]
    n = len(body) // 40 - 1  # the last record is the table tail
    chunks, prev = [], 0
    for i in range(n):
        end = struct.unpack_from("<Q", body, i * 40)[0]
        chunks.append((prev, end - prev, body[i * 40 + 8:i * 40 + 40]))
        prev = end
    return flags, max_sz, chunks


class Assembler:
    def __init__(self, img: str, stores: list[str], chunks, flags: int, max_sz: int, jobs: int):
        import zstandard  # imported here so --help works without it
        self.zstd = zstandard
        self.img, self.stores, self.chunks, self.max_sz, self.jobs = img, stores, chunks, max_sz, jobs
        self.sha512_256 = bool(flags & CA_FORMAT_SHA512_256)
        if self.sha512_256 and "sha512_256" not in hashlib.algorithms_available:
            print("WARNING: no SHA-512/256 in this Python; per-chunk checks skipped "
                  "(the whole image is still checked at the end)", file=sys.stderr)
        self.state_path = img + ".progress"
        self.lock = threading.Lock()
        self.done_bytes = 0
        self.downloaded = 0

    def digest(self, data: bytes) -> bytes | None:
        if self.sha512_256:
            if "sha512_256" not in hashlib.algorithms_available:
                return None
            return hashlib.new("sha512_256", data).digest()
        return hashlib.sha256(data).digest()

    def fetch(self, dg: bytes) -> bytes:
        h = dg.hex()
        for store in self.stores:
            try:
                raw = http_get(f"{store}/{h[:4]}/{h}.cacnk")
            except urllib.error.HTTPError:
                continue
            self.downloaded += len(raw)
            data = self.zstd.ZstdDecompressor().decompress(raw, max_output_size=self.max_sz)
            got = self.digest(data)
            if got is not None and got != dg:
                raise RuntimeError(f"chunk {h} failed its digest check")
            return data
        raise RuntimeError(f"chunk {h} not found in any chunk store")

    def run(self) -> None:
        total = self.chunks[-1][0] + self.chunks[-1][1]
        # Group offsets by chunk digest: identical chunks (often zeros) are fetched once.
        by_digest: dict[bytes, list[tuple[int, int]]] = {}
        for off, ln, dg in self.chunks:
            by_digest.setdefault(dg, []).append((off, ln))
        done = set()
        if os.path.exists(self.state_path) and os.path.exists(self.img):
            with open(self.state_path) as f:
                done = {bytes.fromhex(x) for x in f.read().split()}
        mode = "r+b" if os.path.exists(self.img) else "w+b"
        fd = open(self.img, mode)
        fd.truncate(total)
        todo = [dg for dg in by_digest if dg not in done]
        self.done_bytes = sum(ln for dg in done for _, ln in by_digest[dg])
        log(f"{len(by_digest)} unique chunks, {len(todo)} to fetch")
        state = open(self.state_path, "a")
        start, last = time.time(), 0.0

        def work(dg: bytes) -> bytes:
            data = self.fetch(dg)
            with self.lock:
                if data.count(0) != len(data):  # all-zero chunks stay as holes
                    for off, _ in by_digest[dg]:
                        fd.seek(off)
                        fd.write(data)
                self.done_bytes += sum(ln for _, ln in by_digest[dg])
            return dg

        with concurrent.futures.ThreadPoolExecutor(self.jobs) as ex:
            for dg in ex.map(work, todo):
                with self.lock:
                    state.write(dg.hex() + "\n")
                now = time.time()
                if now - last > 5:
                    last = now
                    mb = self.downloaded / 1e6
                    print(f"    {100 * self.done_bytes / total:5.1f}%  downloaded {mb:,.0f} MB "
                          f"({mb / max(now - start, 1):.1f} MB/s)", flush=True)
                    state.flush()
        state.close()
        fd.flush()
        os.fsync(fd.fileno())
        fd.close()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--channel", default="stable", choices=["stable", "rc", "beta", "main"])
    ap.add_argument("--out", default="valve-rootfs", help="output directory (default: ./valve-rootfs)")
    ap.add_argument("--jobs", type=int, default=8, help="parallel chunk downloads (default 8)")
    ap.add_argument("--accept-new-signer", action="store_true", help="continue if Valve's signing key changed")
    ap.add_argument("--bundle-only", action="store_true", help="only download and verify the bundle")
    args = ap.parse_args()

    for tool in ("openssl", "unsquashfs"):
        if not shutil.which(tool):
            die(f"{tool} is missing (Debian/Armbian: sudo apt install openssl squashfs-tools)")

    cand = read_manifest(args.channel)
    image = cand["image"]
    build, version = image["buildid"], image["version"]
    update_path = cand["update_path"]
    bundle_name = os.path.basename(update_path)
    log(f"Valve SteamOS {image.get('variant')} {args.channel}: build {build}, version {version}")

    outdir = os.path.join(args.out, build)
    os.makedirs(outdir, exist_ok=True)
    bundle = os.path.join(outdir, bundle_name)
    if not os.path.exists(bundle):
        log(f"Downloading {bundle_name}")
        data = http_get(IMAGES_URL + update_path, timeout=120)
        with open(bundle + ".part", "wb") as f:
            f.write(data)
        os.replace(bundle + ".part", bundle)

    with tempfile.TemporaryDirectory(dir=outdir) as tmp:
        sig, payload = split_bundle(bundle, tmp)
        signer = verify_bundle(sig, payload, tmp, args.accept_new_signer, bundle)
        log(f"Bundle signature OK ({signer['signer'].splitlines()[0]})")
        extract = os.path.join(tmp, "bundle")
        subprocess.run(["unsquashfs", "-q", "-n", "-d", extract, payload], check=True,
                       stdout=subprocess.DEVNULL)
        with open(os.path.join(extract, "manifest.raucm")) as f:
            raucm_text = f.read()
        shutil.copy(os.path.join(extract, "rootfs.img.caibx"), os.path.join(outdir, "rootfs.img.caibx"))
    with open(os.path.join(outdir, "manifest.raucm"), "w") as f:
        f.write(raucm_text)
    raucm = parse_raucm(raucm_text)
    if raucm.get("update.compatible") != EXPECTED_COMPATIBLE:
        die(f"unexpected bundle compatible={raucm.get('update.compatible')}")
    want_sha = raucm["image.rootfs.sha256"]
    want_size = int(raucm["image.rootfs.size"])

    info = {"channel": args.channel, "buildid": build, "version": version, "bundle": bundle_name,
            "compatible": raucm["update.compatible"], "rootfs_sha256": want_sha,
            "rootfs_size": want_size, **signer}
    with open(os.path.join(outdir, "info.json"), "w") as f:
        json.dump(info, f, indent=2)
    if args.bundle_only:
        log(f"Bundle verified. Details in {outdir}/info.json")
        return

    img = os.path.join(outdir, "rootfs.img")
    if os.path.exists(img + ".verified"):
        log(f"{img} already verified")
        print(img)
        return
    flags, max_sz, chunks = parse_caibx(os.path.join(outdir, "rootfs.img.caibx"))
    if chunks[-1][0] + chunks[-1][1] != want_size:
        die("chunk index size does not match the signed manifest")
    stores = [IMAGES_URL + os.path.splitext(update_path)[0] + ".castr",
              IMAGES_URL + cand.get("chunks_store_path", "vr/chunks.castr")]
    log(f"Rebuilding rootfs.img ({want_size / 2**30:.0f} GiB, sparse) from Valve's chunk stores")
    Assembler(img, stores, chunks, flags, max_sz, args.jobs).run()

    log("Checking the whole image against the signed sha256 (takes a minute)")
    got = sha256_file(img)
    if got != want_sha:
        os.replace(img + ".progress", img + ".progress.bad")
        die(f"rootfs.img sha256 mismatch: got {got}, want {want_sha}. Delete {outdir} and retry.")
    open(img + ".verified", "w").write(want_sha + "\n")
    try:
        os.remove(img + ".progress")
    except FileNotFoundError:
        pass
    log(f"rootfs.img verified: {img}")
    print(img)


if __name__ == "__main__":
    main()
