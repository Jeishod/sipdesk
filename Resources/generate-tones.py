import math
import pathlib
import struct
import sys
import wave


def generate(path, duration, sound):
    rate = 24000
    samples = bytearray()
    for index in range(int(rate * duration)):
        value = max(-1.0, min(1.0, sound(index / rate)))
        samples.extend(struct.pack("<h", int(value * 18000)))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(samples)


def ringtone(seconds):
    if seconds < 0.5:
        local, frequency = seconds, 784
    elif 0.68 <= seconds < 1.18:
        local, frequency = seconds - 0.68, 1046.5
    else:
        return 0
    envelope = min(1, local / 0.015) * math.exp(-local * 5) * min(1, (0.5 - local) / 0.03)
    return envelope * (math.sin(2 * math.pi * frequency * local) * 0.65 + math.sin(2 * math.pi * frequency * 2 * local) * 0.12)


def ringback(seconds):
    if seconds >= 2:
        return 0
    envelope = min(1, seconds / 0.025, (2 - seconds) / 0.025)
    return envelope * (math.sin(2 * math.pi * 440 * seconds) + math.sin(2 * math.pi * 480 * seconds)) * 0.25


directory = pathlib.Path(sys.argv[1])
directory.mkdir(parents=True, exist_ok=True)
generate(directory / "ringtone.wav", 3.2, ringtone)
generate(directory / "ringback.wav", 6, ringback)

