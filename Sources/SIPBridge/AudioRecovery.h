#ifndef SIPDESK_AUDIO_RECOVERY_H
#define SIPDESK_AUDIO_RECOVERY_H

#include <stdint.h>

void sd_audio_monitor_start(const char *input_name, const char *output_name);
void sd_audio_monitor_stop(void);
void sd_audio_monitor_play_frame(void);
int sd_audio_monitor_needs_recovery(void);
void sd_audio_monitor_recovered(void);

#endif
