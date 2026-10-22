# Third-party components

SIPDesk statically links **PJSIP / pjproject 2.17-dev**, published by Teluu:

- Pinned source: https://github.com/pjsip/pjproject/tree/c7fa6bfb85172f038cf37986696a16b3987391ea
- Upstream commit date: 2026-10-21.
- Archive SHA-256: `a1c0d3e97b240d8ea71f599f3538d81fc3f8b1237154cef9accc604f5f3b3cda`
- Upstream licensing: https://www.pjsip.org/licensing.htm
- PJSIP is offered under GPL version 2 or later, or a separate commercial license from Teluu.

This is a pinned development snapshot, not an unreleased version presented as a
stable release. The older 2.17 release has subsequently published security
advisories, including SDP parsing and SIP transport lifetime defects. The
upstream fixes are in the pinned snapshot. Builds never follow a moving branch.
Relevant upstream notices:

- https://github.com/pjsip/pjproject/security/advisories/GHSA-rfwg-w9gq-9mw2
- https://github.com/pjsip/pjproject/security/advisories/GHSA-48g5-c24v-cfmw
- https://github.com/pjsip/pjproject/security/advisories/GHSA-3659-543c-qm3g

The bootstrap script retains upstream notices for PJSIP and bundled Speex,
libresample, and libsrtp. `build.sh` includes them in
`SIPDesk.app/Contents/Resources/Licenses/`. Speex is built for acoustic echo
cancellation; the application's enabled voice codecs are G.711 and G.722.

This project is prepared for local use. Before distributing an application that
links PJSIP, choose the appropriate upstream licensing path and review all
bundled component licenses. No commercial PJSIP license is included here.

The icon is rendered locally with AppKit and an Apple SF Symbol. The ringtone
and ringback tone are synthesized by `Resources/generate-tones.py`.
