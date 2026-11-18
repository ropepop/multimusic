import copy
from datetime import datetime
import io
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from signing_entitlements import inspect_unsigned_archive, signing_entitlements, verify_signed_entitlements


class SigningEntitlementsTests(unittest.TestCase):
    def profile(self, prefix="FREE000001"):
        return {"ApplicationIdentifierPrefix": [prefix], "TeamIdentifier": [prefix],
                "CreationDate": datetime(2000, 1, 1), "ExpirationDate": datetime(2099, 1, 1),
                "Entitlements": {"application-identifier": prefix + ".*",
                    "com.apple.developer.team-identifier": prefix, "get-task-allow": True,
                    "keychain-access-groups": [prefix + ".*", "com.apple.token"]}}

    def test_recipient_prefixes_produce_only_concrete_private_and_shared_groups(self):
        for prefix in ("FREE000001", "OTHER00002"):
            with self.subTest(prefix=prefix):
                profile = self.profile(prefix)
                original = copy.deepcopy(profile)
                actual = signing_entitlements(profile, "com.example.MultiMusic", prefix + ".com.example.MultiMusic.playback")
                self.assertEqual(actual, {"application-identifier": prefix + ".com.example.MultiMusic",
                    "com.apple.developer.team-identifier": prefix, "get-task-allow": True,
                    "keychain-access-groups": [prefix + ".com.example.MultiMusic", prefix + ".com.example.MultiMusic.playback"]})
                self.assertEqual(profile, original)

    def test_explicit_spotify_profile_keeps_default_group_first(self):
        profile = self.profile()
        profile["Entitlements"]["application-identifier"] = "FREE000001.com.example.MultiMusic.Spotify"
        profile["Entitlements"]["keychain-access-groups"] = [
            "FREE000001.com.example.MultiMusic.playback", "FREE000001.com.example.MultiMusic.Spotify"]
        del profile["Entitlements"]["get-task-allow"]
        actual = signing_entitlements(profile, "com.example.MultiMusic.Spotify", "FREE000001.com.example.MultiMusic.playback")
        self.assertEqual(actual["application-identifier"], "FREE000001.com.example.MultiMusic.Spotify")
        self.assertEqual(actual["keychain-access-groups"], [
            "FREE000001.com.example.MultiMusic.Spotify", "FREE000001.com.example.MultiMusic.playback"])
        self.assertFalse(actual["get-task-allow"])

    def test_rejects_identity_mismatches_and_unapproved_wildcards(self):
        cases = [
            ("application-identifier", "FREE000001.com.someone.Other"),
            ("application-identifier", "FREE000001.com.example.*.Music"),
            ("keychain-access-groups", ["FREE000001.com.example.MultiMusic"]),
            ("keychain-access-groups", ["FREE000001.*.playback"]),
            ("keychain-access-groups", ["FREE000001.com.example.MultiMusicExtra.*"]),
            ("keychain-access-groups", ["*"]),
            ("com.apple.developer.team-identifier", "OTHER00002"),
            ("get-task-allow", "true"),
        ]
        for key, value in cases:
            profile = self.profile()
            profile["Entitlements"][key] = value
            with self.subTest(field=key, value=value), self.assertRaises(ValueError):
                signing_entitlements(profile, "com.example.MultiMusic", "FREE000001.com.example.MultiMusic.playback")
        for shared in (None, "OTHER00002.com.example.MultiMusic.playback", "FREE000001.*"):
            with self.subTest(shared=shared), self.assertRaises(ValueError):
                signing_entitlements(self.profile(), "com.example.MultiMusic", shared)
        for key, value in (("ExpirationDate", datetime(2001, 1, 1)),
                           ("CreationDate", datetime(2098, 1, 1)),
                           ("ApplicationIdentifierPrefix", ["OTHER00002"])):
            profile = self.profile()
            profile[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                signing_entitlements(profile, "com.example.MultiMusic", "FREE000001.com.example.MultiMusic.playback")

    def test_actual_codesign_readback_rejects_missing_or_added_grants(self):
        grants = signing_entitlements(self.profile(), "com.example.MultiMusic", "FREE000001.com.example.MultiMusic.playback")
        with tempfile.TemporaryDirectory(prefix="multimusic-entitlement-check-") as directory:
            directory = Path(directory)
            binary = directory / "probe"
            entitlements = directory / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps(grants))
            subprocess.run(["xcrun", "clang", "-x", "c", "-o", binary, "-"],
                           input=b"int main(void) { return 0; }\n", check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements, binary], check=True, capture_output=True)
            readback = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", binary], check=True, capture_output=True)
            actual = plistlib.loads(readback.stdout)
            verify_signed_entitlements(actual, grants)
            missing = copy.deepcopy(actual)
            missing["keychain-access-groups"].pop()
            with self.assertRaises(ValueError):
                verify_signed_entitlements(missing, grants)
            actual["unrequested-permission"] = True
            with self.assertRaises(ValueError):
                verify_signed_entitlements(actual, grants)


class SigningArchiveTests(unittest.TestCase):
    def archive(self, app="youtube", changes=None, extra=None):
        product, provider, adapter = (("Multimusic", "youtubeMusic", "YouTubeMusic.js") if app == "youtube"
                                      else ("MultimusicSpotify", "spotify", "Spotify.js"))
        prefix = "Payload/" + product + ".app/"
        info = {"CFBundleIdentifier": "com.example.MultiMusic" + (".Spotify" if app == "spotify" else ""),
                "CFBundleExecutable": product, "MultimusicSourceProvider": provider,
                "MultimusicPrimaryBundleIdentifier": "com.example.MultiMusic",
                "SharedPlaybackKeychainAccessGroup": "com.example.MultiMusic.playback",
                "MultimusicDiagnosticsOrigin": "", "MultimusicDiagnosticsDatabase": ""}
        info.update(changes or {})
        output = io.BytesIO()
        with warnings.catch_warnings(), zipfile.ZipFile(output, "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
            executable = zipfile.ZipInfo(prefix + product)
            executable.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(executable, b"fixture executable")
            archive.writestr(prefix + adapter, b"fixture adapter")
            if extra:
                archive.writestr(*extra)
        output.seek(0)
        return output

    def test_both_provider_archives_are_checked_before_signing(self):
        for app, provider in (("youtube", "youtubeMusic"), ("spotify", "spotify")):
            with self.subTest(app=app):
                info, adapter = inspect_unsigned_archive(self.archive(app), app)
                self.assertEqual(info["MultimusicSourceProvider"], provider)
                self.assertEqual(adapter, b"fixture adapter")

    def test_rejects_unsafe_layout_and_changed_provider_or_private_diagnostics(self):
        for path in ("../escape", "/Payload/escape", "Payload/Other.app/Info.plist",
                     "Payload\\escape", "Payload/Multimusic.app/Info.plist", "Payload/Multimusic.app/Spotify.js",
                     "Payload/Multimusic.app/./Multimusic", "Payload/Multimusic.app//Multimusic",
                     "Payload/Multimusic.app/multimusic"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                inspect_unsigned_archive(self.archive(extra=(path, b"unexpected")), "youtube")
        link = zipfile.ZipInfo("Payload/Multimusic.app/link")
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(ValueError):
            inspect_unsigned_archive(self.archive(extra=(link, b"/tmp/elsewhere")), "youtube")
        for change in ({"MultimusicSourceProvider": "spotify"}, {"CFBundleIdentifier": "com.other.App"},
                       {"CFBundleExecutable": "../other"}, {"MultimusicDiagnosticsOrigin": "https://example.invalid"},
                       {"MultimusicDiagnosticsDatabase": "private-database"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                inspect_unsigned_archive(self.archive(changes=change), "youtube")

    def test_cli_rejects_invalid_archive_without_password_prompt_or_output(self):
        with tempfile.TemporaryDirectory(prefix="multimusic-signing-rejection-") as directory:
            directory = Path(directory)
            source = directory / "unsafe.ipa"
            source.write_bytes(self.archive(extra=("../escape", b"unexpected")).getvalue())
            identity = directory / "recipient.p12"
            profile = directory / "recipient.mobileprovision"
            identity.write_text("unused fixture")
            profile.write_text("unused fixture")
            output = directory / "signed"
            env = dict(os.environ)
            env.pop("MULTIMUSIC_SIGN_PASSWORD", None)
            env.pop("MULTIMUSIC_SIGN_PASSWORD_FILE", None)
            result = subprocess.run(["sh", ROOT / "scripts/sign.sh", "--bundle-base", "com.example.MultiMusic",
                "--shared-group", "FREE000001.com.example.MultiMusic.playback", source, identity, profile, output],
                input=b"", capture_output=True, env=env, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Unexpected archive layout", result.stderr)
            self.assertNotIn(b"password", result.stderr.lower())
            self.assertFalse(output.exists())
            self.assertFalse((directory / "escape").exists())

    def test_cli_rejects_self_signed_provisioning_even_when_cms_decoder_accepts_it(self):
        with tempfile.TemporaryDirectory(prefix="multimusic-profile-authentication-") as directory:
            directory = Path(directory)
            key, certificate = directory / "fixture-key.pem", directory / "fixture-cert.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                "-out", certificate, "-days", "1", "-subj", "/CN=Untrusted Signing Fixture"], check=True, capture_output=True)
            certificate_der = subprocess.check_output(["openssl", "x509", "-in", certificate, "-outform", "DER"])
            profile_data = SigningEntitlementsTests().profile()
            profile_data.update(Platform=["iOS"], ProvisionedDevices=["0" * 40], DeveloperCertificates=[certificate_der])
            plain = directory / "profile.plist"
            plain.write_bytes(plistlib.dumps(profile_data))
            profile = directory / "untrusted.mobileprovision"
            subprocess.run(["openssl", "cms", "-sign", "-signer", certificate, "-inkey", key, "-in", plain,
                "-outform", "DER", "-out", profile, "-nodetach", "-binary"], check=True, capture_output=True)
            decoded = subprocess.run(["security", "cms", "-D", "-i", profile], check=True, capture_output=True)
            self.assertEqual(plistlib.loads(decoded.stdout), profile_data)
            source = directory / "app.ipa"
            source.write_bytes(self.archive().getvalue())
            identity = directory / "unused.p12"
            identity.write_text("not opened before profile authentication")
            output = directory / "signed"
            result = subprocess.run(["sh", ROOT / "scripts/sign.sh", "--bundle-base", "com.example.MultiMusic",
                "--shared-group", "FREE000001.com.example.MultiMusic.playback", source, identity, profile, output],
                input=b"", capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"could not be authenticated against Apple's roots", result.stderr)
            self.assertNotIn(b"password", result.stderr.lower())
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
