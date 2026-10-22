# Security

## Project status

SipDesk v0.1.0 is an early-stage release. Security
fixes are developed against the current source; there is no guaranteed response
or patch timeline. Ad-hoc local builds are not notarized releases. Review the
pinned dependency and upstream advisories in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Reporting a vulnerability

**Do not disclose an exploitable vulnerability or secrets in a public issue.**
Private vulnerability reporting is enabled on GitHub. Use
[Report a vulnerability](https://github.com/Jeishod/sipdesk/security/advisories/new)
in the repository's Security tab. No dedicated security email or guaranteed
response timeline is provided.

Include affected source revision, macOS/architecture, minimal synthetic
reproduction, expected impact and suggested mitigation. Never include real SIP
passwords, Keychain exports, account JSON, unredacted packet captures, phone
numbers, private PBX addresses or personal call history.

## Data and trust boundaries

Passwords are stored in macOS Keychain under `local.sipdesk.accounts`, keyed by
profile UUID, with device-only accessibility and synchronization disabled.
Settings and history JSON are not encrypted. Their application-support directory
uses `0700` permissions; files are written atomically with `0600` permissions.
Access to your user account or device can expose local metadata.

TLS validates server certificates through Apple's networking stack. UDP/TCP SIP
and ordinary RTP are plaintext; TLS alone protects signaling, not media. Use
TLS with required SRTP when the provider supports it. SDES key exchange must not
be used over plaintext SIP. Private CA trust is an administrator responsibility;
SipDesk does not install trust roots or offer a certificate bypass.

SIP URI input is validated; external links fill the dialer without automatic
calling. Incoming REFER/Replaces and automatic redirects are rejected. Caller ID
is remote data, not authentication. No call recording or telemetry is implemented.
Microphone permission is obtained in Settings before calling; capture is not
started for registration or idle monitoring.

Synthetic previews and loopback tests do not establish provider security,
physical audio operation or emergency-calling suitability. Do not use SipDesk as
your only way to reach emergency services.
