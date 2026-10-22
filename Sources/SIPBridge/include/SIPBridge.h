#ifndef SIPDESK_BRIDGE_H
#define SIPDESK_BRIDGE_H

#include <stdint.h>

enum SDEventType {
    SD_EVENT_REGISTRATION = 1,
    SD_EVENT_INCOMING = 2,
    SD_EVENT_CALL = 3,
    SD_EVENT_MEDIA = 4,
    SD_EVENT_DTMF = 5,
    SD_EVENT_WARNING = 6,
    SD_EVENT_REJECTED = 7,
    SD_EVENT_AUDIO_RECOVERED = 8
};

typedef struct {
    int32_t generation;
    const char *identity;
    const char *registrar;
    const char *username;
    const char *password;
    const char *proxy;
    const char *stun_server;
    int32_t transport;
    int32_t ipv6;
    int32_t local_port;
    int32_t media_encryption;
    int32_t use_ice;
    int32_t register_account;
} SDAccountConfig;

typedef struct {
    int32_t type;
    int32_t generation;
    int32_t call_id;
    int32_t state;
    int32_t code;
    int32_t incoming;
    int32_t media_state;
    int32_t registered;
    uint64_t call_token;
    char remote_uri[1024];
    char display_name[256];
    char message[256];
} SDEvent;

typedef struct {
    int32_t device_id;
    int32_t input_channels;
    int32_t output_channels;
    char name[256];
    char driver[64];
} SDAudioDevice;

typedef struct {
    uint32_t tx_packets;
    uint32_t rx_packets;
    uint32_t rx_lost;
    double rtt_ms;
    double jitter_ms;
    int32_t secure_media;
    int32_t input_level;
    int32_t output_level;
    char codec[64];
} SDCallStatistics;

int32_t sd_initialize(int32_t headless);
void sd_shutdown(void);
void sd_poll(int32_t timeout_ms);
int32_t sd_next_event(SDEvent *event);
int32_t sd_connect(const SDAccountConfig *config);
int32_t sd_disconnect(int32_t generation);
int32_t sd_local_port(void);
int32_t sd_active_call_id(void);
uint64_t sd_active_call_token(void);
int32_t sd_dial(const char *uri, int32_t *call_id);
int32_t sd_answer(int32_t call_id);
int32_t sd_hangup(int32_t call_id, int32_t status_code);
int32_t sd_set_mute(int32_t call_id, int32_t muted);
int32_t sd_set_hold(int32_t call_id, int32_t held);
int32_t sd_send_dtmf(int32_t call_id, const char *digits, int32_t use_sip_info);
int32_t sd_audio_devices(SDAudioDevice *devices, int32_t capacity, int32_t refresh);
int32_t sd_enable_sound(int32_t capture_id, int32_t playback_id);
int32_t sd_disable_sound(void);
int32_t sd_recover_sound(void);
int32_t sd_call_statistics(int32_t call_id, SDCallStatistics *statistics);
int32_t sd_network_changed(void);
int32_t sd_probe_tone(int32_t call_id);
void sd_error_message(int32_t status, char *buffer, int32_t capacity);
const char *sd_version(void);

#endif

