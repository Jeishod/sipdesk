# Contributing

SipDesk is early-stage software. Discuss substantial changes in an issue before
starting work. Its own-code license is undecided; resolve licensing with the
maintainer before submitting substantial code or redistributing builds.

## Local setup and checks

Use Apple Silicon, macOS 14+, Swift 6+ and Python 3. From the project root:

```sh
./build.sh
./Scripts/test.sh
```

The first run downloads the pinned PJSIP dependency. Do not commit `.dependencies`,
Swift build directories, packaged apps, signing material or local account data.
Headless CI runs Swift and loopback tests only. Packaged GUI checks are local:

```sh
SIPDESK_TEST_APP="$PWD/build/SIPDesk.app" python3 -m unittest discover -s Tests/Integration -p test_tray_ui.py -v
python3 -m unittest discover -s Tests/Integration -p test_audio_capture_policy.py -v
```

These checks require a graphical macOS session. Neither synthetic rendering nor
loopback RTP proves that a physical microphone or headset works.

## Change guidelines

- Keep changes focused; add regression tests and update relevant documentation.
- Keep PJSUA work on its dedicated persistent thread, not a serial GCD queue.
  Deliver UI changes on MainActor; preserve call tokens and ordered runtime events.
- Preserve UUID-keyed Keychain credentials, profile migrations and history. Do not
  bypass certificate validation or request microphone permission during a call.
- Never make paid calls or connect to a real account as part of an automated test.
- Include what changed, checks run and remaining limitations in the pull request.
  UI evidence must use synthetic preview data with network and Keychain disabled.
- Pin GitHub Actions to full commit SHAs. CI must not use real SIP credentials,
  prompt for GUI permissions or publish application artifacts.

Report ordinary bugs with the issue template. For vulnerabilities, follow
[SECURITY.md](SECURITY.md), not a public issue. The original detailed architecture
and local-build notes are in [docs/development.md](docs/development.md).
