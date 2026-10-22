#include "AudioRecovery.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>

static atomic_uint_fast64_t last_change;
static atomic_uint_fast64_t playback_frames;
static uint64_t observed_frames;
static uint64_t last_playback;
static uint64_t last_recovery;
static unsigned recovery_attempts;
static AudioObjectID monitored_devices[2];
static unsigned monitored_count;
static int monitoring;

static uint64_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static OSStatus property_changed(AudioObjectID object, UInt32 count,
                                 const AudioObjectPropertyAddress addresses[], void *context) {
    (void)object;
    (void)context;
    for (UInt32 index = 0; index < count; ++index) {
        switch (addresses[index].mSelector) {
            case kAudioDevicePropertyVolumeScalar:
            case kAudioDevicePropertyVolumeDecibels:
            case kAudioDevicePropertyMute:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyStreamConfiguration:
            case kAudioHardwarePropertyDefaultInputDevice:
            case kAudioHardwarePropertyDefaultOutputDevice:
                atomic_store(&last_change, milliseconds());
                break;
            default: break;
        }
    }
    return noErr;
}

static AudioObjectID resolve_device(const char *name, AudioObjectPropertySelector default_selector) {
    AudioObjectPropertyAddress address = {default_selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID result = kAudioObjectUnknown;
    UInt32 size = sizeof(result);
    if (!name || !name[0]) {
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &result);
        return result;
    }
    AudioObjectID devices[128];
    size = sizeof(devices);
    address.mSelector = kAudioHardwarePropertyDevices;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) return result;
    unsigned count = size / sizeof(AudioObjectID);
    address.mSelector = kAudioObjectPropertyName;
    for (unsigned index = 0; index < count; ++index) {
        CFStringRef device_name = NULL;
        size = sizeof(device_name);
        if (AudioObjectGetPropertyData(devices[index], &address, 0, NULL, &size, &device_name) == noErr && device_name) {
            char buffer[256];
            int matches = CFStringGetCString(device_name, buffer, sizeof(buffer), kCFStringEncodingUTF8) && strcmp(buffer, name) == 0;
            CFRelease(device_name);
            if (matches) return devices[index];
        }
    }
    return result;
}

static const AudioObjectPropertyAddress device_address = {
    kAudioObjectPropertySelectorWildcard, kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementWildcard
};
static const AudioObjectPropertyAddress input_address = {
    kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};
static const AudioObjectPropertyAddress output_address = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

void sd_audio_monitor_stop(void) {
    if (!monitoring) return;
    for (unsigned index = 0; index < monitored_count; ++index) {
        AudioObjectRemovePropertyListener(monitored_devices[index], &device_address, property_changed, NULL);
    }
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &input_address, property_changed, NULL);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &output_address, property_changed, NULL);
    monitored_count = 0;
    monitoring = 0;
}

void sd_audio_monitor_start(const char *input_name, const char *output_name) {
    sd_audio_monitor_stop();
    atomic_store(&last_change, 0);
    observed_frames = atomic_load(&playback_frames);
    last_playback = milliseconds();
    last_recovery = 0;
    recovery_attempts = 0;
    AudioObjectID devices[2] = {
        resolve_device(input_name, kAudioHardwarePropertyDefaultInputDevice),
        resolve_device(output_name, kAudioHardwarePropertyDefaultOutputDevice)
    };
    for (unsigned index = 0; index < 2; ++index) {
        if (devices[index] == kAudioObjectUnknown || (index == 1 && devices[1] == devices[0])) continue;
        if (AudioObjectAddPropertyListener(devices[index], &device_address, property_changed, NULL) == noErr) {
            monitored_devices[monitored_count++] = devices[index];
        }
    }
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &input_address, property_changed, NULL);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &output_address, property_changed, NULL);
    monitoring = 1;
}

void sd_audio_monitor_play_frame(void) {
    atomic_fetch_add(&playback_frames, 1);
}

int sd_audio_monitor_needs_recovery(void) {
    if (!monitoring) return 0;
    uint64_t now = milliseconds();
    uint64_t frames = atomic_load(&playback_frames);
    if (frames != observed_frames) {
        observed_frames = frames;
        last_playback = now;
        if (now - last_recovery > 5000) recovery_attempts = 0;
    }
    uint64_t changed = atomic_load(&last_change);
    if (changed && now - changed < 350) return 0;
    if (now - last_recovery < 2000 || recovery_attempts >= 3) return 0;
    if (!changed && now - last_playback < 1500) return 0;
    if (changed && !atomic_compare_exchange_strong(&last_change, &changed, 0)) return 0;
    last_recovery = now;
    last_playback = now;
    ++recovery_attempts;
    return 1;
}

void sd_audio_monitor_recovered(void) {
    last_playback = milliseconds();
    observed_frames = atomic_load(&playback_frames);
}
