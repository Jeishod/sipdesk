#include "SIPBridge.h"
#include "AudioRecovery.h"
#include <pjsua-lib/pjsua.h>
#include <pjmedia/tonegen.h>
#include <pjmedia/transport_srtp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define SD_QUEUE_CAPACITY 256

static pthread_t owner_thread;
static pthread_mutex_t event_mutex = PTHREAD_MUTEX_INITIALIZER;
static SDEvent event_queue[SD_QUEUE_CAPACITY];
static unsigned queue_read;
static unsigned queue_write;
static atomic_int active_call = -1;
static atomic_uint_fast64_t call_token_counter = 0;
static atomic_uint_fast64_t active_call_token = 0;
static atomic_int generation = 0;
static atomic_bool muted = 0;
static atomic_bool shutting_down = 0;
static atomic_bool accept_incoming = 0;
static atomic_bool unregister_finished = 0;
static atomic_bool account_disconnecting = 0;
static pjsua_acc_id account_id = PJSUA_INVALID_ID;
static pjsua_transport_id transport_id = PJSUA_INVALID_ID;
static pj_pool_t *tone_pool;
static pjmedia_port *tone_port;
static pjsua_conf_port_id tone_slot = PJSUA_INVALID_ID;
static int initialized;
static int headless_mode;
static int sound_enabled;
static char selected_input[256];
static char selected_output[256];

static void on_play_frame(pjmedia_frame *frame) {
    (void)frame;
    sd_audio_monitor_play_frame();
}

static int on_owner_thread(void) {
    return initialized && pthread_equal(pthread_self(), owner_thread);
}

static void copy_string(char *destination, size_t capacity, const pj_str_t *source) {
    if (!capacity) return;
    size_t length = source && source->slen > 0 ? (size_t)source->slen : 0;
    if (length >= capacity) length = capacity - 1;
    if (length) memcpy(destination, source->ptr, length);
    destination[length] = '\0';
}

static void enqueue(SDEvent event) {
    if (atomic_load(&shutting_down)) return;
    event.generation = atomic_load(&generation);
    pthread_mutex_lock(&event_mutex);
    unsigned next = (queue_write + 1) % SD_QUEUE_CAPACITY;
    if (next == queue_read) queue_read = (queue_read + 1) % SD_QUEUE_CAPACITY;
    event_queue[queue_write] = event;
    queue_write = next;
    pthread_mutex_unlock(&event_mutex);
}

static void emit_warning(pj_status_t status, const char *operation) {
    SDEvent event = {0};
    event.type = SD_EVENT_WARNING;
    event.call_id = -1;
    event.code = status;
    char detail[PJ_ERR_MSG_SIZE];
    pj_strerror(status, detail, sizeof(detail));
    snprintf(event.message, sizeof(event.message), "%s: %.180s", operation, detail);
    enqueue(event);
}

static SDEvent call_event(int type, const pjsua_call_info *info) {
    SDEvent event = {0};
    event.type = type;
    event.call_id = info->id;
    event.call_token = info->id == atomic_load(&active_call) ? atomic_load(&active_call_token) : 0;
    event.state = info->state;
    event.code = info->last_status;
    event.incoming = info->role == PJSIP_ROLE_UAS;
    event.media_state = info->media_status;
    copy_string(event.remote_uri, sizeof(event.remote_uri), &info->remote_info);
    copy_string(event.message, sizeof(event.message), &info->last_status_text);
    const char *opening = strchr(event.remote_uri, '<');
    if (opening && opening > event.remote_uri) {
        const char *start = event.remote_uri;
        const char *end = opening;
        while (start < end && (*start == ' ' || *start == '"')) ++start;
        while (end > start && (end[-1] == ' ' || end[-1] == '"')) --end;
        pj_str_t name = {(char *)start, end - start};
        copy_string(event.display_name, sizeof(event.display_name), &name);
    }
    return event;
}

static void on_registration(pjsua_acc_id changed_id, pjsua_reg_info *registration) {
    if (changed_id != account_id) return;
    pjsua_acc_info info;
    if (pjsua_acc_get_info(changed_id, &info) != PJ_SUCCESS) return;
    SDEvent event = {0};
    event.type = SD_EVENT_REGISTRATION;
    event.call_id = -1;
    event.code = info.reg_last_err ? info.reg_last_err : (int)info.status;
    event.registered = info.status >= 200 && info.status < 300 && info.expires > 0;
    if (registration && !registration->renew) atomic_store(&unregister_finished, 1);
    atomic_store(&accept_incoming, event.registered && !atomic_load(&account_disconnecting) && !atomic_load(&shutting_down));
    if (info.reg_last_err) pj_strerror(info.reg_last_err, event.message, sizeof(event.message));
    else copy_string(event.message, sizeof(event.message), &info.status_text);
    enqueue(event);
}

static void on_incoming(pjsua_acc_id incoming_account, pjsua_call_id call_id, pjsip_rx_data *data) {
    (void)data;
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) return;
    if (!atomic_load(&accept_incoming)) {
        pjsua_call_answer(call_id, PJSIP_SC_TEMPORARILY_UNAVAILABLE, NULL, NULL);
        return;
    }
    int expected = -1;
    if (incoming_account != account_id || account_id == PJSUA_INVALID_ID ||
        !atomic_compare_exchange_strong(&active_call, &expected, call_id)) {
        SDEvent event = call_event(SD_EVENT_REJECTED, &info);
        event.code = PJSIP_SC_BUSY_HERE;
        enqueue(event);
        pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, NULL, NULL);
        return;
    }
    atomic_store(&muted, 0);
    atomic_store(&active_call_token, atomic_fetch_add(&call_token_counter, 1) + 1);
    enqueue(call_event(SD_EVENT_INCOMING, &info));
    pjsua_call_answer(call_id, PJSIP_SC_RINGING, NULL, NULL);
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *data) {
    (void)data;
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) return;
    if (info.role == PJSIP_ROLE_UAC && info.acc_id == account_id && info.state == PJSIP_INV_STATE_CALLING) {
        int expected = -1;
        if (atomic_compare_exchange_strong(&active_call, &expected, call_id)) {
            atomic_store(&active_call_token, atomic_fetch_add(&call_token_counter, 1) + 1);
        }
    }
    if (call_id != atomic_load(&active_call)) return;
    enqueue(call_event(SD_EVENT_CALL, &info));
    if (info.state == PJSIP_INV_STATE_DISCONNECTED) {
        int expected = call_id;
        atomic_compare_exchange_strong(&active_call, &expected, -1);
        atomic_store(&active_call_token, 0);
        atomic_store(&muted, 0);
        if (tone_slot != PJSUA_INVALID_ID && info.conf_slot != PJSUA_INVALID_ID) {
            pjsua_conf_disconnect(tone_slot, info.conf_slot);
        }
    }
}

static void on_media_state(pjsua_call_id call_id) {
    if (call_id != atomic_load(&active_call)) return;
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) return;
    enqueue(call_event(SD_EVENT_MEDIA, &info));
    if (info.media_status == PJSUA_CALL_MEDIA_ACTIVE || info.media_status == PJSUA_CALL_MEDIA_REMOTE_HOLD) {
        for (unsigned index = 0; index < info.media_cnt; ++index) {
            const pjsua_call_media_info *media = &info.media[index];
            if (media->type != PJMEDIA_TYPE_AUDIO || media->stream.aud.conf_slot == PJSUA_INVALID_ID) continue;
            if (media->status != PJSUA_CALL_MEDIA_ACTIVE && media->status != PJSUA_CALL_MEDIA_REMOTE_HOLD) continue;
            pj_status_t status = pjsua_conf_connect(media->stream.aud.conf_slot, 0);
            if (status != PJ_SUCCESS) emit_warning(status, "Audio playback");
            if (!atomic_load(&muted)) {
                status = pjsua_conf_connect(0, media->stream.aud.conf_slot);
                if (status != PJ_SUCCESS) emit_warning(status, "Audio capture");
            }
        }
    } else if (info.media_status == PJSUA_CALL_MEDIA_ERROR) {
        emit_warning(PJMEDIA_EBADFMT, "Audio negotiation");
        pjsua_call_hangup(call_id, PJSIP_SC_NOT_ACCEPTABLE_HERE, NULL, NULL);
    }
}

static void on_dtmf(pjsua_call_id call_id, const pjsua_dtmf_info *info) {
    if (call_id != atomic_load(&active_call)) return;
    SDEvent event = {0};
    event.type = SD_EVENT_DTMF;
    event.call_id = call_id;
    event.message[0] = (char)info->digit;
    enqueue(event);
}

static void reject_transfer(pjsua_call_id call_id, const pj_str_t *destination,
                            pjsip_status_code *code, pjsua_call_setting *settings) {
    (void)call_id;
    (void)destination;
    (void)settings;
    *code = PJSIP_SC_DECLINE;
}

static void reject_replace(pjsua_call_id call_id, pjsip_rx_data *data, int *code,
                           pj_str_t *text, pjsua_call_setting *settings) {
    (void)call_id;
    (void)data;
    (void)text;
    (void)settings;
    *code = PJSIP_SC_DECLINE;
}

static pjsip_redirect_op reject_redirect(pjsua_call_id call_id, const pjsip_uri *target, const pjsip_event *event) {
    (void)call_id;
    (void)target;
    (void)event;
    return PJSIP_REDIRECT_REJECT;
}

static void on_transport(pjsip_transport *transport, pjsip_transport_state state, const pjsip_transport_state_info *info) {
    (void)transport;
    if (state == PJSIP_TP_STATE_DISCONNECTED && info->status != PJ_SUCCESS && account_id != PJSUA_INVALID_ID) {
        emit_warning(info->status, "SIP transport");
    }
}

int32_t sd_initialize(int32_t headless) {
    if (initialized) return PJ_EEXISTS;
    owner_thread = pthread_self();
    atomic_store(&shutting_down, 0);
    atomic_store(&accept_incoming, 0);
    atomic_store(&account_disconnecting, 0);
    atomic_store(&active_call, -1);
    atomic_store(&muted, 0);
    queue_read = queue_write = 0;
    headless_mode = headless;
    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) return status;
    pj_log_set_level(0);
    pjsua_config config;
    pjsua_config_default(&config);
    config.thread_cnt = 0;
    config.max_calls = 4;
    config.user_agent = pj_str("SIPDesk/0.1");
    config.cb.on_reg_state2 = on_registration;
    config.cb.on_incoming_call = on_incoming;
    config.cb.on_call_state = on_call_state;
    config.cb.on_call_media_state = on_media_state;
    config.cb.on_dtmf_digit2 = on_dtmf;
    config.cb.on_call_transfer_request2 = reject_transfer;
    config.cb.on_call_replace_request2 = reject_replace;
    config.cb.on_call_redirected = reject_redirect;
    config.cb.on_transport_state = on_transport;
    pjsua_logging_config logging;
    pjsua_logging_config_default(&logging);
    logging.msg_logging = PJ_FALSE;
    logging.level = 0;
    logging.console_level = 0;
    pjsua_media_config media;
    pjsua_media_config_default(&media);
    media.clock_rate = 16000;
    media.snd_clock_rate = 0;
    media.channel_count = 1;
    media.ec_tail_len = headless ? 0 : 200;
    /* macOS VoiceProcessingIO may ignore selected device IDs and stall its
     * Bluetooth aggregate. Use HAL capture/playback with Speex software EC;
     * this policy also survives device recovery and account reinitialization. */
    media.ec_options = headless ? 0 : PJMEDIA_ECHO_USE_SW_ECHO | PJMEDIA_ECHO_SPEEX;
    media.no_vad = PJ_TRUE;
    media.snd_auto_close_time = 1;
    media.on_aud_prev_play_frame = on_play_frame;
    status = pjsua_init(&config, &logging, &media);
    if (status != PJ_SUCCESS) { pjsua_destroy(); return status; }
    status = pjsua_start();
    if (status != PJ_SUCCESS) { pjsua_destroy(); return status; }
    status = pjsua_set_null_snd_dev();
    if (status != PJ_SUCCESS) { pjsua_destroy(); return status; }
    initialized = 1;
    sound_enabled = 0;
    pjsua_codec_info codecs[64];
    unsigned count = 64;
    if (pjsua_enum_codecs(codecs, &count) == PJ_SUCCESS) {
        for (unsigned index = 0; index < count; ++index) {
            pj_uint8_t priority = 0;
            if (pj_strnicmp2(&codecs[index].codec_id, "PCMU/", 5) == 0) priority = 240;
            if (pj_strnicmp2(&codecs[index].codec_id, "PCMA/", 5) == 0) priority = 239;
            if (pj_strnicmp2(&codecs[index].codec_id, "G722/", 5) == 0) priority = 238;
            pjsua_codec_set_priority(&codecs[index].codec_id, priority);
        }
    }
    return PJ_SUCCESS;
}

void sd_shutdown(void) {
    if (!on_owner_thread()) return;
    atomic_store(&shutting_down, 1);
    sd_audio_monitor_stop();
    atomic_store(&accept_incoming, 0);
    pjsua_call_hangup_all();
    if (tone_slot != PJSUA_INVALID_ID) {
        pjsua_conf_remove_port(tone_slot);
        tone_slot = PJSUA_INVALID_ID;
    }
    if (tone_port) { pjmedia_port_destroy(tone_port); tone_port = NULL; }
    if (tone_pool) { pj_pool_release(tone_pool); tone_pool = NULL; }
    pjsua_destroy();
    account_id = transport_id = PJSUA_INVALID_ID;
    atomic_store(&active_call, -1);
    initialized = 0;
    sound_enabled = 0;
}

void sd_poll(int32_t timeout_ms) {
    if (!on_owner_thread()) return;
    pjsua_handle_events(timeout_ms < 0 ? 0 : (unsigned)timeout_ms);
    if (sound_enabled && !headless_mode && sd_audio_monitor_needs_recovery()) {
        pj_status_t status = sd_recover_sound();
        if (status != PJ_SUCCESS) emit_warning(status, "Audio recovery");
    }
}

int32_t sd_next_event(SDEvent *event) {
    if (!event) return 0;
    pthread_mutex_lock(&event_mutex);
    if (queue_read == queue_write) { pthread_mutex_unlock(&event_mutex); return 0; }
    *event = event_queue[queue_read];
    queue_read = (queue_read + 1) % SD_QUEUE_CAPACITY;
    pthread_mutex_unlock(&event_mutex);
    return 1;
}

int32_t sd_disconnect(int32_t next_generation) {
    if (!on_owner_thread()) return PJ_EINVALIDOP;
    if (atomic_load(&active_call) != -1) return PJ_EBUSY;
    atomic_store(&generation, next_generation);
    atomic_store(&accept_incoming, 0);
    atomic_store(&account_disconnecting, 1);
    if (account_id != PJSUA_INVALID_ID) {
        pjsua_acc_id previous = account_id;
        pjsua_acc_info info;
        if (pjsua_acc_get_info(previous, &info) == PJ_SUCCESS && info.has_registration && info.expires > 0) {
            atomic_store(&unregister_finished, 0);
            if (pjsua_acc_set_registration(previous, PJ_FALSE) == PJ_SUCCESS) {
                pj_time_val started;
                pj_gettickcount(&started);
                while (!atomic_load(&unregister_finished)) {
                    pjsua_handle_events(20);
                    pj_time_val now;
                    pj_gettickcount(&now);
                    PJ_TIME_VAL_SUB(now, started);
                    if (PJ_TIME_VAL_MSEC(now) >= 2000) break;
                }
            }
        }
        account_id = PJSUA_INVALID_ID;
        pjsua_acc_del(previous);
    }
    if (transport_id != PJSUA_INVALID_ID) {
        pjsua_transport_close(transport_id, PJ_TRUE);
        transport_id = PJSUA_INVALID_ID;
    }
    SDEvent event = {0};
    event.type = SD_EVENT_REGISTRATION;
    event.call_id = -1;
    enqueue(event);
    return PJ_SUCCESS;
}

int32_t sd_connect(const SDAccountConfig *settings) {
    if (!on_owner_thread() || !settings || !settings->identity || !settings->registrar || !settings->username || !settings->password) return PJ_EINVAL;
    if (settings->transport < 0 || settings->transport > 2 || settings->media_encryption < 0 || settings->media_encryption > 2) return PJ_EINVAL;
    if (settings->media_encryption && settings->transport != 2) return PJ_EINVAL;
    if (pjsua_verify_sip_url(settings->identity) != PJ_SUCCESS || pjsua_verify_sip_url(settings->registrar) != PJ_SUCCESS) return PJ_EINVAL;
    if (atomic_load(&active_call) != -1) return PJ_EBUSY;
    int previous_headless = headless_mode;
    sd_shutdown();
    pj_status_t status = sd_initialize(previous_headless);
    if (status != PJ_SUCCESS) return status;
    atomic_store(&generation, settings->generation);
    pjsua_transport_config transport;
    pjsua_transport_config_default(&transport);
    transport.port = (unsigned)settings->local_port;
    if (headless_mode) transport.bound_addr = pj_str(settings->ipv6 ? "::1" : "127.0.0.1");
    transport.tls_setting.verify_server = PJ_TRUE;
    transport.tls_setting.verify_client = PJ_FALSE;
    transport.tls_setting.proto = PJ_SSL_SOCK_PROTO_TLS1_2 | PJ_SSL_SOCK_PROTO_TLS1_3;
    pjsip_transport_type_e type = PJSIP_TRANSPORT_UDP;
    if (settings->transport == 1) type = PJSIP_TRANSPORT_TCP;
    if (settings->transport == 2) type = PJSIP_TRANSPORT_TLS;
    if (settings->ipv6) type = (pjsip_transport_type_e)(type + PJSIP_TRANSPORT_IPV6);
    status = pjsua_transport_create(type, &transport, &transport_id);
    if (status != PJ_SUCCESS) return status;
    pj_str_t stun = pj_str((char *)(settings->stun_server ? settings->stun_server : ""));
    if (stun.slen) {
        status = pjsua_update_stun_servers(1, &stun, PJ_FALSE);
        if (status != PJ_SUCCESS && status != PJ_EPENDING) return status;
    }
    pjsua_acc_config config;
    pjsua_acc_config_default(&config);
    config.id = pj_str((char *)settings->identity);
    if (settings->register_account) config.reg_uri = pj_str((char *)settings->registrar);
    config.transport_id = transport_id;
    config.register_on_acc_add = PJ_FALSE;
    config.reg_timeout = 300;
    config.reg_retry_interval = 30;
    config.reg_first_retry_interval = 3;
    config.reg_delay_before_refresh = 15;
    config.ka_interval = 25;
    config.allow_contact_rewrite = PJ_TRUE;
    config.allow_via_rewrite = PJ_TRUE;
    config.allow_sdp_nat_rewrite = PJ_TRUE;
    config.sip_stun_use = stun.slen ? PJSUA_STUN_USE_DEFAULT : PJSUA_STUN_USE_DISABLED;
    config.media_stun_use = stun.slen ? PJSUA_STUN_USE_DEFAULT : PJSUA_STUN_USE_DISABLED;
    config.ipv6_sip_use = settings->ipv6 ? PJSUA_IPV6_ENABLED_USE_IPV6_ONLY : PJSUA_IPV6_DISABLED;
    config.ipv6_media_use = settings->ipv6 ? PJSUA_IPV6_ENABLED_USE_IPV6_ONLY : PJSUA_IPV6_DISABLED;
    config.cred_count = 1;
    config.cred_info[0].realm = pj_str("*");
    config.cred_info[0].scheme = pj_str("digest");
    config.cred_info[0].username = pj_str((char *)settings->username);
    config.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    config.cred_info[0].data = pj_str((char *)settings->password);
    config.use_srtp = (pjmedia_srtp_use)settings->media_encryption;
    config.srtp_secure_signaling = 1;
    config.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM;
    config.ice_cfg.enable_ice = settings->use_ice;
    config.rtp_cfg.port = 40000;
    config.rtp_cfg.port_range = 200;
    config.rtp_cfg.randomize_port = PJ_TRUE;
    if (headless_mode) config.rtp_cfg.bound_addr = pj_str(settings->ipv6 ? "::1" : "127.0.0.1");
    if (settings->proxy && settings->proxy[0]) {
        if (pjsua_verify_sip_url(settings->proxy) != PJ_SUCCESS) return PJ_EINVAL;
        config.proxy_cnt = 1;
        config.proxy[0] = pj_str((char *)settings->proxy);
    }
    status = pjsua_acc_add(&config, PJ_TRUE, &account_id);
    if (status != PJ_SUCCESS) return status;
    if (settings->register_account) return pjsua_acc_set_registration(account_id, PJ_TRUE);
    atomic_store(&accept_incoming, 1);
    SDEvent event = {0};
    event.type = SD_EVENT_REGISTRATION;
    event.call_id = -1;
    event.registered = 1;
    event.code = 200;
    enqueue(event);
    return PJ_SUCCESS;
}

int32_t sd_local_port(void) {
    if (!on_owner_thread() || transport_id == PJSUA_INVALID_ID) return 0;
    pjsua_transport_info info;
    if (pjsua_transport_get_info(transport_id, &info) != PJ_SUCCESS) return 0;
    return pj_sockaddr_get_port(&info.local_addr);
}

int32_t sd_active_call_id(void) {
    return atomic_load(&active_call);
}

uint64_t sd_active_call_token(void) {
    return atomic_load(&active_call_token);
}

static int valid_call(int32_t call_id) {
    return on_owner_thread() && call_id >= 0 && call_id == atomic_load(&active_call) && pjsua_call_is_active(call_id);
}

int32_t sd_dial(const char *uri, int32_t *call_id) {
    if (!on_owner_thread() || !uri || !call_id || account_id == PJSUA_INVALID_ID) return PJ_EINVALIDOP;
    if (atomic_load(&active_call) != -1) return PJ_EBUSY;
    if (!headless_mode && !sound_enabled) return PJ_EINVALIDOP;
    pj_status_t status = pjsua_verify_sip_url(uri);
    if (status != PJ_SUCCESS) return status;
    atomic_store(&muted, 0);
    pj_str_t destination = pj_str((char *)uri);
    pjsua_call_setting settings;
    pjsua_call_setting_default(&settings);
    settings.aud_cnt = 1;
    settings.vid_cnt = 0;
    pjsua_call_id created = PJSUA_INVALID_ID;
    status = pjsua_call_make_call(account_id, &destination, &settings, NULL, NULL, &created);
    if (status == PJ_SUCCESS) *call_id = created;
    return status;
}

int32_t sd_answer(int32_t call_id) {
    if (!valid_call(call_id) || (!headless_mode && !sound_enabled)) return PJ_EINVALIDOP;
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS || info.role != PJSIP_ROLE_UAS || info.state >= PJSIP_INV_STATE_CONNECTING) return PJ_EINVALIDOP;
    pjsua_call_setting settings;
    pjsua_call_setting_default(&settings);
    settings.aud_cnt = 1;
    settings.vid_cnt = 0;
    return pjsua_call_answer2(call_id, &settings, PJSIP_SC_OK, NULL, NULL);
}

int32_t sd_hangup(int32_t call_id, int32_t status_code) {
    if (!valid_call(call_id)) return PJ_EINVALIDOP;
    return pjsua_call_hangup(call_id, (unsigned)status_code, NULL, NULL);
}

int32_t sd_set_mute(int32_t call_id, int32_t next_muted) {
    if (!valid_call(call_id)) return PJ_EINVALIDOP;
    pjsua_call_info info;
    pj_status_t status = pjsua_call_get_info(call_id, &info);
    if (status != PJ_SUCCESS) return status;
    if (info.conf_slot == PJSUA_INVALID_ID) return PJ_EINVALIDOP;
    status = next_muted ? pjsua_conf_disconnect(0, info.conf_slot) : pjsua_conf_connect(0, info.conf_slot);
    if (status == PJ_SUCCESS) atomic_store(&muted, next_muted != 0);
    return status;
}

int32_t sd_set_hold(int32_t call_id, int32_t held) {
    if (!valid_call(call_id)) return PJ_EINVALIDOP;
    if (held) return pjsua_call_set_hold(call_id, NULL);
    return pjsua_call_reinvite(call_id, PJSUA_CALL_UNHOLD, NULL);
}

int32_t sd_send_dtmf(int32_t call_id, const char *digits, int32_t use_sip_info) {
    if (!valid_call(call_id) || !digits || !digits[0] || strlen(digits) > 32) return PJ_EINVAL;
    for (const char *cursor = digits; *cursor; ++cursor) {
        if (!strchr("0123456789*#ABCDabcd", *cursor)) return PJ_EINVAL;
    }
    pjsua_call_send_dtmf_param parameters;
    pjsua_call_send_dtmf_param_default(&parameters);
    parameters.method = use_sip_info ? PJSUA_DTMF_METHOD_SIP_INFO : PJSUA_DTMF_METHOD_RFC2833;
    parameters.duration = 160;
    parameters.digits = pj_str((char *)digits);
    return pjsua_call_send_dtmf(call_id, &parameters);
}

int32_t sd_audio_devices(SDAudioDevice *devices, int32_t capacity, int32_t refresh) {
    if (!on_owner_thread() || !devices || capacity <= 0) return -1;
    if (refresh && atomic_load(&active_call) == -1) pjmedia_aud_dev_refresh();
    pjmedia_aud_dev_info available[64];
    unsigned count = 64;
    if (pjsua_enum_aud_devs(available, &count) != PJ_SUCCESS) return -1;
    if (count > (unsigned)capacity) count = (unsigned)capacity;
    for (unsigned index = 0; index < count; ++index) {
        devices[index].device_id = (int32_t)index;
        devices[index].input_channels = (int32_t)available[index].input_count;
        devices[index].output_channels = (int32_t)available[index].output_count;
        snprintf(devices[index].name, sizeof(devices[index].name), "%s", available[index].name);
        snprintf(devices[index].driver, sizeof(devices[index].driver), "%s", available[index].driver);
    }
    return (int32_t)count;
}

int32_t sd_enable_sound(int32_t capture_id, int32_t playback_id) {
    if (!on_owner_thread()) return PJ_EINVALIDOP;
    if (headless_mode) return PJ_SUCCESS;
    pj_status_t status = pjsua_set_snd_dev(capture_id, playback_id);
    if (status == PJ_SUCCESS) {
        sound_enabled = 1;
        selected_input[0] = selected_output[0] = '\0';
        pjmedia_aud_dev_info info;
        if (capture_id >= 0 && pjmedia_aud_dev_get_info(capture_id, &info) == PJ_SUCCESS) {
            snprintf(selected_input, sizeof(selected_input), "%s", info.name);
        }
        if (playback_id >= 0 && pjmedia_aud_dev_get_info(playback_id, &info) == PJ_SUCCESS) {
            snprintf(selected_output, sizeof(selected_output), "%s", info.name);
        }
        sd_audio_monitor_start(selected_input, selected_output);
    }
    return status;
}

int32_t sd_disable_sound(void) {
    if (!on_owner_thread()) return PJ_EINVALIDOP;
    if (atomic_load(&active_call) != -1) return PJ_EBUSY;
    sd_audio_monitor_stop();
    pj_status_t status = pjsua_set_null_snd_dev();
    if (status == PJ_SUCCESS) sound_enabled = 0;
    return status;
}

int32_t sd_recover_sound(void) {
    if (!on_owner_thread()) return PJ_EINVALIDOP;
    int call_id = atomic_load(&active_call);
    if (call_id < 0) return PJ_EINVALIDOP;
    pjsua_call_info call;
    pj_status_t status = pjsua_call_get_info(call_id, &call);
    if (status != PJ_SUCCESS) return status;
    if (!headless_mode) {
        pjsua_set_no_snd_dev();
        pjmedia_aud_dev_refresh();
        int input = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV;
        int output = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV;
        pjmedia_aud_dev_info devices[64];
        unsigned count = 64;
        if (pjsua_enum_aud_devs(devices, &count) == PJ_SUCCESS) {
            for (unsigned index = 0; index < count; ++index) {
                if (selected_input[0] && devices[index].input_count && strcmp(selected_input, devices[index].name) == 0) input = (int)index;
                if (selected_output[0] && devices[index].output_count && strcmp(selected_output, devices[index].name) == 0) output = (int)index;
            }
        }
        status = pjsua_set_snd_dev(input, output);
        if (status != PJ_SUCCESS) return status;
        sd_audio_monitor_recovered();
    }
    for (unsigned index = 0; index < call.media_cnt; ++index) {
        const pjsua_call_media_info *media = &call.media[index];
        if (media->type != PJMEDIA_TYPE_AUDIO || media->stream.aud.conf_slot == PJSUA_INVALID_ID) continue;
        if (media->status != PJSUA_CALL_MEDIA_ACTIVE && media->status != PJSUA_CALL_MEDIA_REMOTE_HOLD) continue;
        status = pjsua_conf_connect(media->stream.aud.conf_slot, 0);
        if (status != PJ_SUCCESS) return status;
        status = atomic_load(&muted) ? pjsua_conf_disconnect(0, media->stream.aud.conf_slot) : pjsua_conf_connect(0, media->stream.aud.conf_slot);
        if (status != PJ_SUCCESS) return status;
    }
    SDEvent event = call_event(SD_EVENT_AUDIO_RECOVERED, &call);
    enqueue(event);
    return PJ_SUCCESS;
}

int32_t sd_call_statistics(int32_t call_id, SDCallStatistics *statistics) {
    if (!valid_call(call_id) || !statistics) return PJ_EINVALIDOP;
    memset(statistics, 0, sizeof(*statistics));
    pjsua_call_info call;
    pj_status_t status = pjsua_call_get_info(call_id, &call);
    if (status != PJ_SUCCESS) return status;
    unsigned stream_index = 0;
    int found = 0;
    for (unsigned index = 0; index < call.media_cnt; ++index) {
        if (call.media[index].type == PJMEDIA_TYPE_AUDIO && call.media[index].status == PJSUA_CALL_MEDIA_ACTIVE) {
            stream_index = call.media[index].index;
            found = 1;
            break;
        }
    }
    if (!found) return PJ_EINVALIDOP;
    pjsua_stream_stat stats;
    status = pjsua_call_get_stream_stat(call_id, stream_index, &stats);
    if (status != PJ_SUCCESS) return status;
    statistics->tx_packets = stats.rtcp.tx.pkt;
    statistics->rx_packets = stats.rtcp.rx.pkt;
    statistics->rx_lost = stats.rtcp.rx.loss;
    statistics->rtt_ms = stats.rtcp.rtt.mean / 1000.0;
    statistics->jitter_ms = stats.rtcp.rx.jitter.mean / 1000.0;
    pjsua_stream_info stream;
    if (pjsua_call_get_stream_info(call_id, stream_index, &stream) == PJ_SUCCESS && stream.type == PJMEDIA_TYPE_AUDIO) {
        copy_string(statistics->codec, sizeof(statistics->codec), &stream.info.aud.fmt.encoding_name);
    }
    pjmedia_transport_info transport;
    pjmedia_transport_info_init(&transport);
    if (pjsua_call_get_med_transport_info(call_id, stream_index, &transport) == PJ_SUCCESS) {
        for (unsigned index = 0; index < transport.specific_info_cnt; ++index) {
            if (transport.spc_info[index].type == PJMEDIA_TRANSPORT_TYPE_SRTP && transport.spc_info[index].cbsize >= (int)sizeof(pjmedia_srtp_info)) {
                pjmedia_srtp_info info;
                memcpy(&info, transport.spc_info[index].buffer, sizeof(info));
                statistics->secure_media = info.active;
            }
        }
    }
    unsigned input_level = 0;
    unsigned output_level = 0;
    pjsua_conf_get_signal_level(0, &output_level, &input_level);
    statistics->input_level = atomic_load(&muted) ? 0 : (int32_t)input_level;
    statistics->output_level = (int32_t)output_level;
    return PJ_SUCCESS;
}

int32_t sd_network_changed(void) {
    if (!on_owner_thread() || account_id == PJSUA_INVALID_ID) return PJ_EINVALIDOP;
    pjsua_ip_change_param parameters;
    pjsua_ip_change_param_default(&parameters);
    return pjsua_handle_ip_change(&parameters);
}

int32_t sd_probe_tone(int32_t call_id) {
    if (!headless_mode || !valid_call(call_id)) return PJ_EINVALIDOP;
    if (!tone_pool) tone_pool = pjsua_pool_create("sipdesk-test-tone", 1024, 1024);
    if (!tone_pool) return PJ_ENOMEM;
    if (!tone_port) {
        pj_status_t status = pjmedia_tonegen_create(tone_pool, 16000, 1, 320, 16, 0, &tone_port);
        if (status != PJ_SUCCESS) return status;
        pjmedia_tone_desc tone = {0};
        tone.freq1 = 440;
        tone.on_msec = 400;
        tone.off_msec = 100;
        tone.volume = 3000;
        status = pjmedia_tonegen_play(tone_port, 1, &tone, PJMEDIA_TONEGEN_LOOP);
        if (status != PJ_SUCCESS) return status;
        status = pjsua_conf_add_port(tone_pool, tone_port, &tone_slot);
        if (status != PJ_SUCCESS) return status;
    }
    pjsua_call_info info;
    pj_status_t status = pjsua_call_get_info(call_id, &info);
    if (status != PJ_SUCCESS || info.conf_slot == PJSUA_INVALID_ID) return PJ_EINVALIDOP;
    return pjsua_conf_connect(tone_slot, info.conf_slot);
}

void sd_error_message(int32_t status, char *buffer, int32_t capacity) {
    if (buffer && capacity > 0) pj_strerror(status, buffer, (pj_size_t)capacity);
}

const char *sd_version(void) {
    return pj_get_version();
}
