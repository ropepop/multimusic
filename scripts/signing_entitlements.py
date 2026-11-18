"""Validate recipient-owned provisioning and the unsigned app before signing."""

from datetime import datetime, timezone
from pathlib import PurePosixPath
import plistlib
import re
import stat
import unicodedata
import zipfile

KEYS = ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups")
APPS = {
    "youtube": ("Multimusic", "youtubeMusic", "YouTubeMusic.js", "Spotify.js"),
    "spotify": ("MultimusicSpotify", "spotify", "Spotify.js", "YouTubeMusic.js"),
}


def concrete_identifier(value):
    return isinstance(value, str) and len(value) <= 255 and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value) is not None


def permits(pattern, value):
    return isinstance(pattern, str) and (pattern == value or (
        pattern.endswith(".*") and pattern.count("*") == 1
        and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", pattern[:-2]) is not None
        and value.startswith(pattern[:-1])))


def signing_entitlements(profile, bundle_identifier, requested_shared_group):
    if not concrete_identifier(bundle_identifier) or not concrete_identifier(requested_shared_group):
        raise ValueError("Choose concrete bundle and shared Keychain identifiers.")
    try:
        grants = profile["Entitlements"]
        profile_app = grants["application-identifier"]
        app_prefix = profile_app.split(".", 1)[0]
        team = grants["com.apple.developer.team-identifier"]
        groups = grants["keychain-access-groups"]
        expiration = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
        creation = profile["CreationDate"].replace(tzinfo=timezone.utc)
        valid_prefix = re.fullmatch(r"[A-Z0-9]{10}", app_prefix) is not None
        if (not valid_prefix or app_prefix not in profile["ApplicationIdentifierPrefix"]
                or not isinstance(team, str) or re.fullmatch(r"[A-Z0-9]{10}", team) is None
                or team not in profile["TeamIdentifier"]):
            raise ValueError("The profile identity and team are inconsistent.")
    except (KeyError, TypeError, AttributeError):
        raise ValueError("The provisioning profile lacks valid identity, group or date fields.") from None
    now = datetime.now(timezone.utc)
    if expiration <= now or creation > now or creation >= expiration:
        raise ValueError("The provisioning profile is expired or not yet valid.")
    app_identifier = app_prefix + "." + bundle_identifier
    if not permits(profile_app, app_identifier):
        raise ValueError("The provisioning profile does not authorize the selected bundle identifier.")
    if not requested_shared_group.startswith(app_prefix + "."):
        raise ValueError("The shared Keychain group has a different application prefix.")
    if not isinstance(groups, list) or not groups or not all(isinstance(group, str) and group for group in groups):
        raise ValueError("The profile has invalid Keychain access groups.")
    if not all(any(permits(group, requested) for group in groups) for requested in (app_identifier, requested_shared_group)):
        raise ValueError("The profile does not authorize both concrete Keychain groups.")
    debugging = grants.get("get-task-allow", False)
    if not isinstance(debugging, bool):
        raise ValueError("The profile has an invalid debugger permission.")
    # The app's own group stays first so private credentials remain private by default.
    return {"application-identifier": app_identifier, "com.apple.developer.team-identifier": team,
            "get-task-allow": debugging, "keychain-access-groups": list(dict.fromkeys((app_identifier, requested_shared_group)))}


def verify_signed_entitlements(actual, expected):
    if actual != expected:
        raise ValueError("The signed app entitlements differ from the approved grants.")


def inspect_unsigned_archive(source, app_choice):
    product, provider, adapter, excluded_adapter = APPS[app_choice]
    prefix = "Payload/" + product + ".app/"
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        destinations = [unicodedata.normalize("NFD", str(PurePosixPath(name))).casefold() for name in names]
        if len(entries) > 20_000 or len(destinations) != len(set(destinations)) or sum(e.file_size for e in entries) > 536_870_912:
            raise ValueError("The archive has duplicate entries or exceeds the supported app size.")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            mode = stat.S_IFMT(entry.external_attr >> 16)
            canonical = str(path) + ("/" if entry.is_dir() else "")
            if (entry.filename != canonical or path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                    or "\x00" in entry.orig_filename or entry.flag_bits & 1
                    or mode not in (0, stat.S_IFREG, stat.S_IFDIR)
                    or entry.file_size > 134_217_728
                    or (entry.filename not in ("Payload/", prefix) and not entry.filename.startswith(prefix))):
                raise ValueError("Unexpected archive layout, file type or encrypted entry.")
        if archive.testzip() is not None:
            raise ValueError("Input archive failed its integrity check.")
        try:
            if archive.getinfo(prefix + "Info.plist").file_size > 1_048_576:
                raise ValueError("App information exceeds the supported size.")
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            adapter_bytes = archive.read(prefix + adapter)
            executable = archive.getinfo(prefix + product)
        except (KeyError, plistlib.InvalidFileException):
            raise ValueError("The input archive lacks the selected app, executable or adapter.") from None
        base = info.get("MultimusicPrimaryBundleIdentifier") if isinstance(info, dict) else None
        bundle = base + (".Spotify" if app_choice == "spotify" else "") if isinstance(base, str) else None
        if (not concrete_identifier(base) or info.get("CFBundleIdentifier") != bundle
                or info.get("CFBundleExecutable") != product or info.get("MultimusicSourceProvider") != provider
                or not executable.external_attr >> 16 & 0o111
                or prefix + excluded_adapter in names or not adapter_bytes):
            raise ValueError("The input archive does not match the selected app and provider.")
        if any(info.get(key) not in (None, "") for key in ("MultimusicDiagnosticsOrigin", "MultimusicDiagnosticsDatabase")):
            raise ValueError("Public signing refuses apps configured for private remote diagnostics.")
        return info, adapter_bytes
