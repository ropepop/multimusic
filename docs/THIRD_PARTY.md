# Third-party services and tools

The [MIT license](../LICENSE) covers Multimusic's own source and project-owned assets. It does not license third-party websites, recordings, artwork, trademarks or Apple SDKs.

| Component | Role | Source or terms |
| --- | --- | --- |
| Apple Music, MusicKit and MediaPlayer | Catalog access, subscription checks and system playback | [Apple developer documentation](https://developer.apple.com/documentation/musickit) and the terms applicable to the user's Apple account and SDK |
| YouTube Music website | Visible browsing and rendered music metadata | [YouTube Terms of Service](https://www.youtube.com/static?template=terms) |
| Spotify website | Visible browsing and rendered music metadata | [Spotify User Guidelines](https://www.spotify.com/us/legal/user-guidelines/) |
| zsign | Optional local signing tool built separately from pinned upstream source | [Upstream source and MIT license](https://github.com/zhlynn/zsign/tree/614caa8d1ca949e260e5746144aa52d27a4b08d6) |

Provider websites and their audio catalogs are not bundled with this repository. Use the services only with the access and permissions your accounts provide. This project does not grant permission to bypass subscriptions, access controls or service terms, and it does not claim endorsement or App Store approval.

The adapters read rendered music information and replace website playback actions with Apple Music matching. That behavior makes provider rules concerning automated collection and service modification relevant. Public distribution and future store submission should be assessed against the current applicable rules; publishing source code is not evidence of provider permission.

The local zsign setup retains the upstream license and pinned source revision record under the ignored build directory. Any separately redistributed third-party binary must carry its own required notices; the public app downloads do not include the local signing tool.
