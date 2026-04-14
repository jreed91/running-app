#!/usr/bin/env python3
"""
upload_testflight_notes.py

Upload TestFlight "What to Test" notes to App Store Connect via the REST API.

JWT signing uses the system `openssl` binary (always available in Xcode Cloud /
macOS environments) so no third-party Python packages are required.

The build may not exist in App Store Connect immediately after `xcodebuild archive`
completes — Xcode Cloud uploads the IPA as a separate phase. This script polls
with exponential back-off until the build appears (default: up to ~15 minutes).
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ASC_API_BASE = "https://api.appstoreconnect.apple.com/v1"

# ── JWT helpers ───────────────────────────────────────────────────────────────

def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw_ecdsa(der: bytes) -> bytes:
    """Convert a DER-encoded ECDSA signature (ASN.1 SEQUENCE of two INTEGERs)
    to the raw r‖s format required by JWT ES256 (64 bytes total)."""
    assert der[0] == 0x30, "Expected DER SEQUENCE tag"
    idx = 1
    # Length of the outer SEQUENCE (skip it)
    if der[idx] & 0x80:
        idx += 1 + (der[idx] & 0x7F)
    else:
        idx += 1

    def read_int(pos: int):
        assert der[pos] == 0x02, "Expected INTEGER tag"
        pos += 1
        length = der[pos]
        pos += 1
        value = der[pos : pos + length]
        return value, pos + length

    r_bytes, idx = read_int(idx)
    s_bytes, _   = read_int(idx)

    # Strip potential leading zero-padding byte, then left-pad to 32 bytes.
    r = r_bytes.lstrip(b"\x00").rjust(32, b"\x00")
    s = s_bytes.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s


def generate_jwt(key_id: str, issuer_id: str, private_key_pem: str) -> str:
    """Return a signed JWT for App Store Connect API authentication.

    Signing is delegated to the system `openssl` CLI so this module has zero
    third-party dependencies.
    """
    header  = _base64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"},
                                     separators=(",", ":")).encode())
    now     = int(time.time())
    payload = _base64url(json.dumps({"iss": issuer_id, "iat": now,
                                      "exp": now + 1200,
                                      "aud": "appstoreconnect-v1"},
                                     separators=(",", ":")).encode())
    message = f"{header}.{payload}"

    # Normalise PEM: the key may arrive as raw base64 without the header/footer.
    pem = private_key_pem.strip()
    if not pem.startswith("-----"):
        pem = (
            "-----BEGIN PRIVATE KEY-----\n"
            + "\n".join(pem[i : i + 64] for i in range(0, len(pem), 64))
            + "\n-----END PRIVATE KEY-----"
        )

    key_file = None
    try:
        fd, key_file = tempfile.mkstemp(suffix=".p8")
        with os.fdopen(fd, "w") as f:
            f.write(pem)

        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_file, "-binary"],
            input=message.encode(),
            capture_output=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"openssl signing failed: {result.stderr.decode().strip()}"
            )
    finally:
        if key_file and os.path.exists(key_file):
            os.unlink(key_file)

    signature = _der_to_raw_ecdsa(result.stdout)
    return f"{message}.{_base64url(signature)}"


# ── App Store Connect API helpers ─────────────────────────────────────────────

def _api(jwt: str, method: str, path: str, body=None) -> dict:
    url  = ASC_API_BASE + path
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization": f"Bearer {jwt}",
            "Content-Type":  "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"ASC API {method} {path} → HTTP {exc.code}: {exc.read().decode().strip()}"
        ) from exc


def find_build(jwt: str, app_id: str, build_number: str,
               max_attempts: int = 20, initial_delay: int = 30) -> dict:
    """Poll App Store Connect until the build with *build_number* appears.

    Xcode Cloud uploads the IPA after `ci_post_xcodebuild.sh` runs, so the
    build may not be visible in ASC for several minutes. We retry with
    capped exponential back-off (30 s → 60 s → 120 s → … → 120 s max).
    """
    delay = initial_delay
    for attempt in range(1, max_attempts + 1):
        print(f"  [{attempt}/{max_attempts}] Looking for build {build_number} in ASC …")
        try:
            resp   = _api(jwt, "GET",
                          f"/builds?filter[app]={app_id}"
                          f"&filter[version]={build_number}&limit=1")
            builds = resp.get("data", [])
            if builds:
                build_id = builds[0]["id"]
                print(f"  Build found — id: {build_id}")
                return builds[0]
        except RuntimeError as exc:
            print(f"  API error: {exc}")

        if attempt < max_attempts:
            print(f"  Build not visible yet; waiting {delay}s …")
            time.sleep(delay)
            delay = min(delay * 2, 120)

    raise RuntimeError(
        f"Build {build_number} did not appear in App Store Connect after "
        f"{max_attempts} attempts."
    )


def set_whats_new(jwt: str, build_id: str, notes: str, locale: str = "en-US") -> None:
    """Create or update the betaBuildLocalization for *locale* on *build_id*."""
    resp     = _api(jwt, "GET", f"/builds/{build_id}/betaBuildLocalizations")
    existing = [
        loc for loc in resp.get("data", [])
        if loc["attributes"].get("locale") == locale
    ]

    if existing:
        loc_id = existing[0]["id"]
        print(f"  Updating existing betaBuildLocalization {loc_id} …")
        _api(jwt, "PATCH", f"/betaBuildLocalizations/{loc_id}", body={
            "data": {
                "type":       "betaBuildLocalizations",
                "id":         loc_id,
                "attributes": {"whatsNew": notes},
            }
        })
    else:
        print(f"  Creating new betaBuildLocalization for build {build_id} …")
        _api(jwt, "POST", "/betaBuildLocalizations", body={
            "data": {
                "type":       "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": notes},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        })

    print("  TestFlight 'What to Test' notes updated successfully.")


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upload TestFlight 'What to Test' notes via App Store Connect API."
    )
    parser.add_argument("--key-id",      required=True, help="ASC API Key ID")
    parser.add_argument("--issuer-id",   required=True, help="ASC Issuer ID")
    parser.add_argument("--private-key", required=True,
                        help="Contents of the .p8 private key (PEM or raw base64)")
    parser.add_argument("--app-id",      required=True, help="Numeric App ID from ASC")
    parser.add_argument("--build-number",required=True, help="Build number (CI_BUILD_NUMBER)")
    parser.add_argument("--notes",       required=True, help="What to Test text")
    parser.add_argument("--locale",      default="en-US", help="BCP 47 locale (default: en-US)")
    parser.add_argument("--max-attempts",type=int, default=20,
                        help="Max polling attempts while waiting for the build (default: 20)")
    args = parser.parse_args()

    print("Generating App Store Connect JWT …")
    jwt = generate_jwt(args.key_id, args.issuer_id, args.private_key)

    print(f"Waiting for build {args.build_number} to appear in App Store Connect …")
    build = find_build(jwt, args.app_id, args.build_number,
                       max_attempts=args.max_attempts)

    print("Setting 'What to Test' notes …")
    set_whats_new(jwt, build["id"], args.notes, locale=args.locale)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
