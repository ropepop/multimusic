# Privacy

## Website accounts

YouTube Music and Spotify load inside their own web views. Sign-in pages, cookies and account information belong to those services and are subject to their privacy policies. The app preserves the website session on the device. It does not ask you to give a provider password to the app author.

## Music and saved state

The app reads rendered song information needed to find a compatible Apple Music recording. Matching sends search information to Apple's catalog services. Playback uses the system Music app and requires your music permission and subscription.

Saved playback state on the device includes source/catalog identifiers, the submitted queue, position and playback intent so that recovery can be handled safely. The two apps use a shared Keychain group to coordinate who may control playback. A signer's profiles must authorize that group.

## Optional diagnostics

Diagnostic logging is off by default. When you enable it in a public build, bounded technical events remain on the device. Public configuration has no diagnostic server or database, so enabling logging does not send events to the developer's private service.

The local buffer is limited by size, count and age. Turning logging off stops new diagnostic recording. Diagnostic fields are restricted to approved technical values; they are not intended to contain credentials, account details, complete page URLs, song titles or listening history. Saved playback state is separate from that diagnostic buffer.

A developer can deliberately configure their own diagnostic backend in a private build. Such a build is a different configuration and must explain its destination and data handling; it is not the public configuration described here.

## Sharing a bug report

Share only the smallest redacted evidence needed to explain a problem. Check screenshots and logs for account names, profile images, private playlists, device identifiers, cookies and signing data before uploading. Never attach certificates, private keys or provisioning profiles.

The project does not operate an advertising or analytics service. Apple, Google, YouTube, Spotify and GitHub process activity under their respective terms and privacy policies when you use their services.
