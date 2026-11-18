# Release verification

## Status — 18 November 2026

The exact YouTube Music 1.2/build 49 and Spotify 1.0/build 38 unsigned packages listed below passed recipient signing, fresh installation, first launch and Apple Music setup on iPhone. Use the checksums to identify the tested files.

## Verified unsigned packages

Both packages were built with Xcode 27.2 (27B5038j) and use project-only app identifiers. Repeated staged builds reproduced the IPAs byte for byte. A separate rebuild from the exported source differed only in the 16-byte `LC_UUID` build identifier in each executable.

| File | App version/build | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `Multimusic-unsigned.ipa` | YouTube Music 1.2 / 49 | 702810 | `fe251ab6cffef7b7a682d27c02db8bef92bd0bce49e86d7a9c518f5ee1df675e` |
| `MultimusicSpotify-unsigned.ipa` | Spotify 1.0 / 38 | 691170 | `551f399c1afd771cf17365a137c5056775e595d3def89289a8a5d6939ddf1d32` |
| `SHA256SUMS` | Both packages | 187 | `a307da2affe9b562abd43ed5d5885a102db554bfad1da4c3f8de81fec9de748e` |

The staged `SHA256SUMS.sig` passed verification against the pinned Multimusic public key, and both IPAs matched the signed manifest. See the [download verification steps](INSTALL.md#route-b-download-an-ipa-and-sign-it).

## Automated checks

All 220 checks passed (66 Swift tests, 119 web adapter tests, 11 native checks, 8 signing checks, 9 source-export checks and 7 accuracy checks). Both packages passed checksum, ZIP structure, app identity, version, resource and privacy checks. Diagnostics are off by default and stay on the device when enabled. See [Privacy](PRIVACY.md#optional-diagnostics).

## iPhone checks

- The recipient signed both exact packages locally with their own Apple signing files. Both apps installed fresh, opened and passed Apple Music setup.
- Each provider matched all 14 songs on Daft Punk’s *Discovery*. The first two Apple Music recordings observed were “One More Time” and “Aerodynamic,” in that order.
- Spotify’s own Next button advanced the native queue. The signed-out YouTube Music album view had no Next button. Next in iOS Now Playing advanced the native queue for that app.

The iPhone check used the observed recording, playback state and queue advancement. Listening and volume checks were outside its scope.
