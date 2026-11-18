# Release verification

## Status — 18 November 2026

YouTube Music 1.2/build 49 and Spotify 1.0/build 38 are unsigned source-preview candidates with project-only app identifiers. The new downloads need signature and iPhone verification. A version number alone does not identify the downloaded file.

## Revised unsigned candidates

Both packages were built with Xcode 27.2 (27B5038j). Independent builds in two fresh staging directories produced identical files.

| File | App version/build | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `Multimusic-unsigned.ipa` | YouTube Music 1.2 / 49 | 702810 | `fe251ab6cffef7b7a682d27c02db8bef92bd0bce49e86d7a9c518f5ee1df675e` |
| `MultimusicSpotify-unsigned.ipa` | Spotify 1.0 / 38 | 691170 | `551f399c1afd771cf17365a137c5056775e595d3def89289a8a5d6939ddf1d32` |
| `SHA256SUMS` | Both candidates | 187 | `a307da2affe9b562abd43ed5d5885a102db554bfad1da4c3f8de81fec9de748e` |

The local checks passed 66 Swift tests, 119 website adapter tests and all 11 native boundary programs, including queue restore and shared ownership. Seven offline signing checks and nine source-export checks passed. Both packages passed checksum, ZIP, app identity, version and resource checks. The executable and archived files passed the privacy scan, and the ZIP headers contain no extra fields. The apps have remote diagnostics disabled. The checksum manifest still needs the Multimusic signature.

## Earlier 49/38 candidates

Both release-verification copies built from the earlier candidate source upgraded in place on an iPhone using one Apple Personal Team. The regular apps stayed on 47/36 after iOS rejected their upgrades because of a signing identity mismatch. Both apps stayed closed. Those checks apply to the earlier packages. The revised candidates have different app identifiers and file hashes.

Seven controlled Mac handoff replays of the earlier candidate kept the same matching results. Catalog requests fell from three to two for each representative YouTube Music and Spotify album. These runs used synthetic catalog responses.

## Earlier evidence — 17 November 2026

The previous 48/37 unsigned packages were built with Xcode 27.2 from public revision `4baaa3a57745d0ea782a828ce1251eefd79cf7a3`. Both passed Personal Team signing and strict Mac package checks. Source builds 47/36 had installed as separate test copies on an iPhone running iOS 27.3. The earlier local diagnostic checks confirmed that opt-in events stayed local and logging stayed quiet when disabled.

GitHub Actions run 44057586961 passed on public revision `0320df348e76746c69cc330521fe9636363fab1e`, using the `xcode-27` ARM64 image with Xcode 27.1, Swift 6.4 and OpenSSL 4.1.0.

The credential scans, 66 Swift tests, 119 adapter tests, 11 native programs, 8 signing regressions, both unsigned builds and artifact upload all passed without the owner's signing credentials. The downloaded CI artifact and its contained checksums were verified; both apps have the expected versions, icons, provider resources and local-only diagnostic configuration, with no profiles, credentials or personal build paths in their archives.

The hosted run produced separate unsigned artifacts for the earlier public revision. The anonymous source archive for that revision matched all 82 tracked file contents. Public source and hosted checks for 49/38 remain unverified.

## Remaining release gates for the revised files

| Check | Result |
| --- | --- |
| Multimusic signature on checksum manifest and anonymous public download verification | **PENDING** |
| Recipient signing and iPhone installation for both apps | **UNVERIFIED** |
| First launch, music permissions, subscription/storefront and provider login | **UNVERIFIED** |
| Playback state, controls, seeking, finite queue order and expected skips | **UNVERIFIED** |
| Background/lock/reopen, recovery and sustained playback for each app | **UNVERIFIED** |
| Two-app switching and paused/foreign queue preservation | **UNVERIFIED** |
| Update under the same identity preserves login, saved playback and coordination | **UNVERIFIED** |
| Denied permission, interrupted connectivity and local-only diagnostics on the phone | **UNVERIFIED** |

The controlled replays cover their selected samples.
