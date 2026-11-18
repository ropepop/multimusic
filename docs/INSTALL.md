# Installation

## Before you start

Both apps need an iPhone on iOS 18 or later, Apple's Music app and an active Apple Music subscription. The routes below use a Mac, full Xcode, Python 3, and signing files that belong to you. This is a self-install project, not an App Store or one-tap web installation.

**Prerelease verification — 18 November 2026.** The exact YouTube Music 1.2/build 49 and Spotify 1.0/build 38 packages were signed locally by the recipient. Both passed fresh installation, first launch and Apple Music setup on iPhone. See the [verification record](VERIFICATION.md).

Apple explains [developer account limits](https://developer.apple.com/help/account/basics/about-your-developer-account/) and [supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/). Personal Team provisioning normally expires after seven days and is subject to app and device limits. Renewing a signature must retain the same identifiers and shared group if you want to preserve saved state. No purchase or paid enrollment is part of these instructions.

## Route A: build with Xcode

1. Clone or download this repository and open `Multimusic.xcodeproj`. To build the version that corresponds to a binary release, use its matching source tag.
2. Add your existing Apple account in Xcode Settings → Accounts. Choose your team for both app targets and use automatic signing where your account supports the required capabilities.
3. Set `MULTIMUSIC_BUNDLE_BASE` to a unique identifier you control. The YouTube app uses that base. The Spotify app uses the same base followed by `.Spotify`. Unsigned packages use the project default `org.multimusic.app`.
4. Keep the shared Keychain group identical for both apps. The checked-in configuration derives it from `AppIdentifierPrefix`, your bundle base and `.playback`. Do not replace the application prefix with an assumed team ID; those values can differ.
5. Ensure each profile authorizes its app ID, its default Keychain group and that shared group. Enable the required Apple Music service for the app IDs if your account provides that configuration. Do not invent a `com.apple.developer.musickit` signing entitlement: [MusicKit uses an App ID service](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api).
6. Select your connected iPhone, build and run the `Multimusic` scheme, then `MultimusicSpotify`. Complete any normal device trust or Developer Mode steps requested by Xcode/iOS.

Place local build overrides in ignored `Local.xcconfig`. A private pair built in Xcode can retain its existing identifiers by setting `MULTIMUSIC_BUNDLE_BASE` there and continuing to use its own matching signing profiles. Both apps derive their playback service from that base. Keep diagnostic origin/database values empty for local-only diagnostics and keep signing material and account credentials outside the checkout.

Command-line unsigned builds are also available:

```sh
sh scripts/package.sh --app youtube --bundle-base com.example.multimusic
sh scripts/package.sh --app spotify --bundle-base com.example.multimusic
```

These produce `build/Multimusic-unsigned.ipa` and `build/MultimusicSpotify-unsigned.ipa`. An unsigned package cannot be installed directly.

## Route B: download an IPA and sign it

For the prerelease, download `Multimusic-unsigned.ipa`, `MultimusicSpotify-unsigned.ipa`, `SHA256SUMS` and `SHA256SUMS.sig` from the same [GitHub release](../../../releases/tag/2026-11-18). Get the signing scripts from that release's source archive and the pinned [Multimusic public key](Multimusic-release-public.pem) through a trusted copy of the source.

Run the first command in the directory with the public key and downloads. Compare the result with the pinned SHA-256 fingerprint of the DER-encoded public key before running the remaining commands.

`7ce522622400ef8b609653111a83d46fce9efb6c1e6b4d055682f6f5581d6233`

```sh
openssl pkey -pubin -in Multimusic-release-public.pem -outform DER | shasum -a 256
openssl dgst -sha256 -verify Multimusic-release-public.pem -signature SHA256SUMS.sig SHA256SUMS &&
  shasum -a 256 --check --strict SHA256SUMS
```

Expect `Verified OK` for the signature and an `OK` line for each IPA before signing either app for installation.

### Obtain your signing files

Use the same team, bundle base and shared group described in Route A. Xcode can create a development signing identity and profiles when your account supports the configuration. In Xcode Settings → Accounts → Manage Certificates, create or select an Apple Development identity. Export the matching certificate **with its private key** as a password-protected `.p12` using Keychain Access. A certificate without its private key cannot sign an app.

Use the provisioning profiles generated for your two app identifiers, or create matching development profiles through your existing developer account where that feature is available. Apple's [development-profile instructions](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/) describe the required App ID, development certificate and registered device. Xcode-managed profiles can be inspected through Xcode's signing settings; their storage location depends on the Xcode version. Do not use an unrelated profile merely because it contains a valid certificate.

The phone must be covered by the profiles. Both profiles must grant the same shared group. Check that your account can provide the required profiles and MusicKit service.

### Prepare the signer

Install Git, Make, Python 3, pkg-config and the selected full Xcode toolchain from their official sources. The signer also requires the **OpenSSL 3 or 4 executable** on `PATH`, in addition to the OpenSSL development libraries used by the setup command. The macOS-provided LibreSSL executable does not satisfy this requirement. If you use Homebrew:

```sh
brew install pkg-config openssl
export PATH="$(brew --prefix openssl)/bin:$PATH"
openssl version
```

Then run from the matching source checkout:

```sh
sh scripts/setup-signing-tools.sh
```

The setup builds pinned official `zsign` source and records the local binary checksum. It does not install a signing certificate or change your system trust settings.

### Sign both packages

Replace the example bundle base, application prefix and private-file paths below with your own values. The application prefix comes from the profiles' `ApplicationIdentifierPrefix`; it is not a password. The common group must be authorized by both profiles.

```sh
scripts/sign.sh --app youtube \
  --bundle-base com.example.multimusic \
  --shared-group PREFIX.com.example.multimusic.playback \
  Multimusic-unsigned.ipa /path/to/identity.p12 \
  /path/to/youtube.mobileprovision build/Signed-youtube

scripts/sign.sh --app spotify \
  --bundle-base com.example.multimusic \
  --shared-group PREFIX.com.example.multimusic.playback \
  MultimusicSpotify-unsigned.ipa /path/to/identity.p12 \
  /path/to/spotify.mobileprovision build/Signed-spotify
```

Use a new output directory each time. The signer asks for the certificate password without displaying it. Automation may use `MULTIMUSIC_SIGN_PASSWORD_FILE`; keep that file outside the checkout with restricted permissions. Do not put passwords in command arguments, issue reports or shell history.

The signer rejects profiles that do not authorize the requested identity and shared group. It verifies the result and preserves application resources apart from the permitted identity fields. Its local verification record is not a receipt of phone installation. Keep signed packages and their embedded profiles private.

Install the extracted app bundles through Xcode's device tools or the supported `devicectl` command for your selected Xcode:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device DEVICE \
  build/Signed-youtube/Payload/Multimusic.app
xcrun devicectl device install app --device DEVICE \
  build/Signed-spotify/Payload/MultimusicSpotify.app
```

## First playback and updates

1. Open Setup, allow music access and verify that the Apple Music subscription and storefront checks succeed.
2. In Music, turn off Autoplay, Repeat and Shuffle for a predictable finite batch. The app cannot turn off Music's Autoplay setting for you.
3. Sign in to the provider website inside the app when needed. A stalled Google return may require the app's Reload control.
4. Select a known song or a small album. Confirm the displayed Apple Music result and playback state, then try pause, next, previous and seeking. If the signed-out YouTube Music album view has no Next button, use Next in iOS Now Playing.
5. Test locking, reopening and using the companion app. Use explicit Restore when the app cannot safely determine the saved queue's state.

Playback and Setup's reference-song action replace Music's current queue. Before testing a new installation, preserve anything you need from the existing queue. Test copies should use a separate bundle base and shared group rather than overwrite an existing installation.

For updates, retain the same bundle identifiers, signing identity and default/shared Keychain groups. Install over the existing test copy without deleting it, then verify login, saved state and two-app cooperation.

A new bundle base creates a separate installation. Provider sign-in, saved queues, caches and local settings stay with the old installation. The new pair starts with a separate playback ownership record, while both pairs still control the same system Music queue. Use one pair at a time. When updating a pair signed with a custom base from an earlier preview, update both apps together so they use the same playback service.
