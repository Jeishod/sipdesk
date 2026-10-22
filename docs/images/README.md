# Screenshot provenance

These PNGs are real synthetic renders of the app, not photographs or live account
screenshots. Both show the preview banner: network and Keychain are disabled.
The placeholder profile name is synthetic; no real phone number or credentials
are visible. Screenshots document appearance, not successful SIP or audio operation.

| Asset | Local render source (ignored build output) | View |
| --- | --- | --- |
| `dialer.png` | `build/release-0.1.0/SIPDesk.app` | English empty dialer, offline |
| `settings.png` | `build/release-0.1.0/SIPDesk.app` | English language/microphone/profile settings |

Only these approved synthetic renders are included. Do not add screenshots of
real accounts, call history, phone numbers or user desktops. To generate a new
network-free preview after building locally:

```sh
build/SIPDesk.app/Contents/MacOS/SIPDesk --render-preview "$PWD/build/interface.png" --preview-language en
build/SIPDesk.app/Contents/MacOS/SIPDesk --render-preview "$PWD/build/settings.png" --preview-language en --preview-settings
```

Inspect the result for private data before deliberately copying it here.
