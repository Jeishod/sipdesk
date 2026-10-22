"""Exercise the real bridge's audio policy without opening audio or SIP sockets.

This proves selection of software EC, not physical microphone operation.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AudioCapturePolicyTests(unittest.TestCase):
    def test_interactive_initialization_avoids_voice_processing_io(self):
        self.run_policy_probe(headless=False)

    def test_headless_initialization_remains_capture_free(self):
        self.run_policy_probe(headless=True)

    def run_policy_probe(self, headless):
        source = r'''
#include "SIPBridge.h"
#include <pjsua-lib/pjsua.h>
#include <pjsua-lib/pjsua_internal.h>
#include <pjmedia/echo.h>
#include <stdio.h>
int main(int argc, char **argv) {
    int headless = argc > 1;
    int status = sd_initialize(headless);
    if (status) { fprintf(stderr, "initialize failed: %d\n", status); return 2; }
    unsigned tail = pjsua_var.media_cfg.ec_tail_len;
    unsigned options = pjsua_var.media_cfg.ec_options;
    int null_sound = pjsua_var.cap_dev == PJSUA_SND_NULL_DEV;
    sd_shutdown();
    if (!null_sound) { fprintf(stderr, "initialization opened hardware\n"); return 3; }
    if (tail != (headless ? 0 : 200)) {
        fprintf(stderr, "wrong EC tail: %u\n", tail); return 4;
    }
    if (!headless && !(options & PJMEDIA_ECHO_USE_SW_ECHO)) {
        fprintf(stderr, "native EC remains enabled: VoiceProcessingIO can ignore selected devices\n");
        return 5;
    }
    if (!headless && (options & PJMEDIA_ECHO_ALGO_MASK) != PJMEDIA_ECHO_SPEEX) {
        fprintf(stderr, "Speex software EC not selected: %u\n", options); return 6;
    }
    printf("headless=%d null_sound=%d ec_tail_ms=%u ec_options=%u\n", headless, null_sound, tail, options);
    return 0;
}
'''
        # The persistent scratch root avoids system /tmp and contains no PCM.
        scratch = Path.home() / ".hermes/cache/scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="sipdesk-audio-policy-", dir=scratch) as directory:
            directory = Path(directory)
            probe = directory / "policy.c"
            probe.write_text(source)
            binary = directory / "policy"
            command = [
                "clang", "-DPJ_AUTOCONF=1", "-I", str(ROOT / ".dependencies/pjsip/include"),
                "-I", str(ROOT / "Sources/SIPBridge/include"), str(probe),
                str(ROOT / "Sources/SIPBridge/SIPBridge.c"),
                str(ROOT / "Sources/SIPBridge/AudioRecovery.c"),
                str(ROOT / ".dependencies/pjsip/lib/libSIPStack.a"), "-lc++",
            ]
            for framework in ("CoreAudio", "AudioToolbox", "AudioUnit", "CoreServices", "Foundation", "AppKit", "Network", "Security"):
                command += ["-framework", framework]
            command += ["-o", str(binary)]
            built = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)] + (["headless"] if headless else []),
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
