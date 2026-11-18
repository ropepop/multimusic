#!/bin/sh
set -eu
exec python3 - "$0" "$@" <<'PY'
import argparse
import getpass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import zipfile

os.umask(0o077)
root = Path(sys.argv[1]).resolve().parent.parent
sys.path.insert(0, str(root / "scripts"))
from signing_entitlements import APPS, KEYS, concrete_identifier, inspect_unsigned_archive, signing_entitlements, verify_signed_entitlements

parser = argparse.ArgumentParser(prog="scripts/sign.sh", description="Sign one public Multimusic IPA using your own certificate and device provisioning profile.")
parser.add_argument("--app", choices=APPS, default="youtube")
parser.add_argument("--bundle-base", required=True, help="Your concrete YouTube bundle ID; Spotify uses this ID plus .Spotify")
parser.add_argument("--shared-group", required=True, help="Your profile's application prefix followed by .BUNDLE-BASE.playback")
parser.add_argument("unsigned_ipa")
parser.add_argument("identity_p12")
parser.add_argument("profile")
parser.add_argument("output_directory")
args = parser.parse_args(sys.argv[2:])
password_file = os.environ.pop("MULTIMUSIC_SIGN_PASSWORD_FILE", None)
password = os.environ.pop("MULTIMUSIC_SIGN_PASSWORD", None)
product, provider, adapter, excluded_adapter = APPS[args.app]
bundle = args.bundle_base + (".Spotify" if args.app == "spotify" else "")
if (not concrete_identifier(args.bundle_base) or not concrete_identifier(bundle)
        or not concrete_identifier(args.shared_group)
        or args.shared_group.split(".", 1)[1] != args.bundle_base + ".playback"):
    parser.error("Use concrete identifiers and the common PREFIX.BUNDLE-BASE.playback Keychain group.")
source, identity, profile, output = [Path(p).expanduser().resolve() for p in (
    args.unsigned_ipa, args.identity_p12, args.profile, args.output_directory)]
for path in (source, identity, profile):
    if not path.is_file() or path == output or output in path.parents:
        raise SystemExit("Inputs must be existing files outside the new output directory.")
if output.exists():
    raise SystemExit("Output directory already exists; choose a new directory.")

def interrupted(number, _frame):
    raise SystemExit(128 + number)

for number in (signal.SIGHUP, signal.SIGTERM):
    signal.signal(number, interrupted)

def run(arguments, **kwargs):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed (exit {result.returncode}); no signed result retained.")
    return result

digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
created = False
try:
    selected_info, adapter_bytes = inspect_unsigned_archive(source, args.app)
    for command in ("openssl", "security", "ditto", "codesign", "zip"):
        if not shutil.which(command):
            raise ValueError("Missing signing dependency: " + command)
    if not re.match(rb"OpenSSL [34]\.", run(["openssl", "version"]).stdout):
        raise ValueError("Use OpenSSL 3 or 4 on PATH for the verified signing workflow.")
    with tempfile.TemporaryDirectory(prefix="multimusic-profile-check-") as profile_check:
        profile_check = Path(profile_check)
        anchors = profile_check / "apple-roots.pem"
        anchors.write_bytes(run(["security", "find-certificate", "-a", "-p", "-c", "Apple Root CA",
                                 "/System/Library/Keychains/SystemRootCertificates.keychain"]).stdout)
        profile_signer = profile_check / "verified-profile-signer.pem"
        # Match Apple's provisioning policy: Apple roots and the dedicated profile signer, not a developer leaf.
        try:
            verified = run(["openssl", "cms", "-verify", "-inform", "DER", "-in", profile,
                            "-CAfile", anchors, "-no-CApath", "-no-CAstore", "-purpose", "any",
                            "-no_check_time", "-signer", profile_signer]).stdout
        except RuntimeError:
            raise ValueError("The provisioning profile could not be authenticated against Apple's roots.") from None
        if profile_signer.read_bytes().count(b"-----BEGIN CERTIFICATE-----") != 1:
            raise ValueError("Expected one verified Apple provisioning-profile signer.")
        names = run(["openssl", "x509", "-in", profile_signer, "-noout", "-subject", "-issuer", "-nameopt", "RFC2253"]).stdout.decode().splitlines()
        if (len(names) != 2 or not re.search(r"(?:^|,)CN=Apple iPhone OS Provisioning Profile Signing(?:,|$)", names[0].split("=", 1)[1])
                or not re.search(r"(?:^|,)CN=Apple iPhone Certification Authority(?:,|$)", names[1].split("=", 1)[1])):
            raise ValueError("The profile was not signed by Apple's iOS provisioning authority.")
        profile_data = plistlib.loads(verified)
    entitlements = signing_entitlements(profile_data, bundle, args.shared_group)
    if (not isinstance(profile_data.get("ProvisionedDevices"), list) or not profile_data["ProvisionedDevices"]
            or "iOS" not in profile_data.get("Platform", [])):
        raise ValueError("Use an iOS development or ad hoc profile containing your registered device.")
    tool = root / "build/tools/zsign"
    tool_info = json.loads((root / "build/tools/zsign-provenance.json").read_text())
    if (tool_info.get("repository") != "https://github.com/zhlynn/zsign"
            or tool_info.get("commit") != "614caa8d1ca949e260e5746144aa52d27a4b08d6"
            or tool_info.get("version") != "1.1.2" or digest(tool) != tool_info.get("sha256")):
        raise ValueError("Run scripts/setup-signing-tools.sh to build the pinned official signer and record its checksum.")
    if password_file:
        password = Path(password_file).expanduser().read_text().rstrip("\r\n")
    elif password is None:
        password = getpass.getpass("Signing certificate password: ")
    if "\n" in password or "\r" in password:
        raise ValueError("The signing password must be a single line.")

    # Keys and passwords never enter the output directory or process arguments.
    with tempfile.TemporaryDirectory(prefix="multimusic-private-sign-") as temporary:
        temporary = Path(temporary)
        private = temporary / "identity.pem"
        try:
            run(["openssl", "pkcs12", "-in", identity, "-nodes", "-out", private, "-passin", "stdin"], input=(password + "\n").encode())
        except RuntimeError:
            run(["openssl", "pkcs12", "-legacy", "-in", identity, "-nodes", "-out", private, "-passin", "stdin"], input=(password + "\n").encode())
        password = None
        private.chmod(0o600)
        certificate = temporary / "certificate.pem"
        run(["openssl", "x509", "-in", private, "-out", certificate])
        certificate_der = run(["openssl", "x509", "-in", certificate, "-outform", "DER"]).stdout
        if certificate_der not in profile_data.get("DeveloperCertificates", []):
            raise ValueError("The supplied certificate is not authorized by this provisioning profile.")
        dates = run(["openssl", "x509", "-in", certificate, "-noout", "-dates"]).stdout.decode().splitlines()
        not_before, not_after = [datetime.strptime(line.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc) for line in dates]
        if not not_before <= datetime.now(timezone.utc) < not_after:
            raise ValueError("The signing certificate is expired or not yet valid.")
        run(["security", "verify-cert", "-c", certificate, "-p", "codeSign", "-q"])
        key_public = run(["openssl", "pkey", "-in", private, "-pubout", "-outform", "DER"]).stdout
        cert_public_pem = run(["openssl", "x509", "-in", certificate, "-noout", "-pubkey"]).stdout
        cert_public = run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=cert_public_pem).stdout
        if key_public != cert_public:
            raise ValueError("The certificate and private key do not match.")
        output.mkdir(parents=True)
        created = True
        run(["ditto", "-x", "-k", source, output])
        app = output / "Payload" / (product + ".app")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info != selected_info or (app / adapter).read_bytes() != adapter_bytes or (app / excluded_adapter).exists():
            raise ValueError("The extracted app differs from the verified archive.")
        # Only recipient identity fields may change; the provider and all behavior stay fixed.
        info.update(CFBundleIdentifier=bundle, MultimusicPrimaryBundleIdentifier=args.bundle_base,
                    SharedPlaybackKeychainAccessGroup=args.shared_group)
        info_bytes = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
        (app / "Info.plist").write_bytes(info_bytes)
        executable = app / product
        if not os.access(executable, os.X_OK):
            raise ValueError("The app executable has no executable permission.")
        executable_mode = executable.stat().st_mode & 0o777
        def resources():
            return {str(p.relative_to(app)): digest(p) for p in app.rglob("*") if p.is_file()
                    and p != executable and p.name != "embedded.mobileprovision"
                    and "_CodeSignature" not in p.relative_to(app).parts}
        before_resources = resources()
        grants = temporary / "entitlements.plist"
        grants.write_bytes(plistlib.dumps(entitlements))
        run([tool, "-q", "-f", "-k", private, "-c", certificate, "-m", profile, "-e", grants, app], cwd=temporary)
        # zsign rewrites this file under our private umask; retain its launch permissions.
        executable.chmod(executable_mode)
        if resources() != before_resources or (app / "Info.plist").read_bytes() != info_bytes:
            raise ValueError("Signing changed an unapproved app resource.")
        if (app / "embedded.mobileprovision").read_bytes() != profile.read_bytes():
            raise ValueError("The signed app contains an unexpected provisioning profile.")
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
        signed_entitlements = plistlib.loads(run(["codesign", "--display", "--entitlements", "-", "--xml", app]).stdout)
        verify_signed_entitlements(signed_entitlements, entitlements)
        cert_prefix = temporary / "signed-certificate-"
        run(["codesign", "--display", "--extract-certificates=" + str(cert_prefix), app])
        if Path(str(cert_prefix) + "0").read_bytes() != certificate_der:
            raise ValueError("The actual signing certificate differs from the supplied certificate.")
        status = run([tool, "-C", executable])
        certificate_text = re.sub(r"\x1b\[[0-9;]*m", "", (status.stdout + status.stderr).decode())
        if not re.search(r"OCSP:\s+Valid\b", certificate_text):
            raise ValueError("A valid online certificate status was not established.")
    signed = output / (product + "-signed.ipa")
    run(["zip", "-X", "-q", "-r", signed, "Payload"], cwd=output)
    signed_info, signed_adapter = inspect_unsigned_archive(signed, args.app)
    if signed_info != info or signed_adapter != adapter_bytes:
        raise ValueError("Signed archive verification failed.")
    provenance = {"signer": tool_info, "unsignedSHA256": digest(source), "signedSHA256": digest(signed),
                  "profileSHA256": digest(profile), "bundleIdentifier": bundle, "app": args.app,
                  "adapterResource": adapter, "adapterSHA256": digest(app / adapter),
                  "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                  "entitlementKeys": list(KEYS), "sharedKeychainGroup": args.shared_group,
                  "profileAuthenticatedByApple": True, "signingCertificateTrust": "passed",
                  "profileIdentityMatchesBundle": True, "profileCertificateMatchesSignature": True,
                  "resourcesUnchangedExceptRecipientIdentity": True, "signedEntitlementsReadback": "passed",
                  "appleStrictSignatureVerification": "passed", "certificateOCSP": "valid",
                  "profileExpires": profile_data["ExpirationDate"].isoformat() + "Z",
                  "privateSigningMaterialRemoved": True, "installed": False,
                  "limit": "Mac signing verification is not device acceptance. Keep this signed package private; it contains your device provisioning profile."}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Signed {info.get('CFBundleShortVersionString')} build {info.get('CFBundleVersion')}: {signed}")
    print("Apple strict signature, recipient identity, certificate, resources and ZIP integrity passed; device install still needs verification.")
except BaseException as error:
    if created:
        shutil.rmtree(output)
    if isinstance(error, (ValueError, RuntimeError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException)):
        raise SystemExit("Signing failed: " + str(error)) from None
    raise
PY
