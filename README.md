# Multimusic

Two independent iPhone apps for browsing music in YouTube Music or Spotify and playing matching recordings through Apple Music.

| App | Browsing interface | Xcode scheme |
| --- | --- | --- |
| Multimusic | YouTube Music website | `Multimusic` |
| Multimusic Spotify | Spotify website | `MultimusicSpotify` |

Both apps use your Apple Music subscription for sound. They read the music information made available by the visible website, find compatible Apple Music recordings, and hand a finite queue to the system Music player. They do not download or play the providers' audio.

## Release status

**Prerelease verification — 21 November 2026.** Automated checks passed for YouTube Music 1.3 (52) and Spotify 1.1 (41). The owner confirmed playback on iPhone with Feather using builds 51/40, which differ from 52/41 only in version numbers. The full iPhone checklist was not rerun for 52/41. See the [verification record](docs/VERIFICATION.md).

Setup shows when Feather or another signer leaves the app using a private keychain. Queue protection works within each app in this mode. The two apps cannot see each other’s playback ownership.

For the prerelease, download the unsigned IPAs and signed checksum manifest from [GitHub Releases](../../releases/tag/2026-11-21).

## Requirements and installation

- An iPhone running iOS 18 or later, the Music app, and an active Apple Music subscription.
- A Mac with full Xcode for the documented installation and signing routes.
- Your own valid Apple signing identity and provisioning profiles for the two apps, with a common Keychain sharing group.
- Access to the relevant provider website; sign in there when the page requires it.

Start with [Installation](docs/INSTALL.md). It covers building from source and signing downloaded unsigned IPAs. Neither route uses the author's certificates or provisioning profiles. Signing eligibility, expiration and renewal depend on your Apple account and profiles.

## What it does

- Uses the provider's visible browsing interface with Apple Music playback and queue controls.
- Matches titles, artists, recording versions, explicitness and available durations; uncertain or conflicting matches are skipped.
- Starts the first accepted recording, then appends the verified remainder in order.
- Preserves saved queue intent and coordinates playback ownership between the two apps.
- Provides optional bounded diagnostics on the device; public builds have no configured diagnostic upload service.

## Known limits

Captured batches contain at most 50 songs that the website has made available. This is not a promise to copy an entire playlist or endless radio queue. Website changes can require an adapter update.

The signed-out YouTube Music album view tested here had no Next button. Use Next in iOS Now Playing in that case.

Matching is based on catalog information and cannot prove that every recording is acoustically identical. An explicit source may use a clean recording when the explicit version is unavailable; the app reports this as `cleanFallback`. A clean source is not silently replaced with an explicit recording. Labeled alternate recordings such as live versions and remixes retain separate matching checks.

Music remains authoritative. Complete queue inspection and rollback are not available in every situation. Clearing stops playback and records the cleared state, but Music may later restore an old item paused. Video, lyrics, library changes and listening-history synchronization are outside the current feature set.

## Development checks

Select your installed full Xcode, then run:

```sh
swift test
node --test Tests/WebAdapter/*.test.mjs
python3 Tests/Native/run_checks.py
python3 -m unittest discover -s Tests/Signing
sh scripts/package.sh --app youtube
sh scripts/package.sh --app spotify
```

The [checks workflow](.github/workflows/checks.yml) runs these checks and creates unsigned candidate packages. See the [verification record](docs/VERIFICATION.md) for on-device coverage.

## Project information

[Privacy](docs/PRIVACY.md) · [Support](.github/SUPPORT.md) · [Security](SECURITY.md) · [Third-party services and tools](docs/THIRD_PARTY.md) · [MIT license](LICENSE)

Multimusic is an independent project and is not affiliated with or endorsed by Apple, Google, YouTube or Spotify. The MIT license covers this repository's own code and assets, not the third-party services it displays.
