#ifndef IPTV_CLEARKEY_H
#define IPTV_CLEARKEY_H

#include <stdint.h>

typedef struct IPTVRelay IPTVRelay;
typedef enum {
    IPTVRelayConnectingPlayer = 1,
    IPTVRelayOpeningManifest,
    IPTVRelayReadingMedia,
    IPTVRelaySelectingVideo,
    IPTVRelayCheckingVideo,
    IPTVRelaySendingVideo
} IPTVRelayStage;

typedef struct {
    IPTVRelayStage stage;
    int failed;
    int http_status;
    int source_error;
    int network_error;
} IPTVRelayStatus;

IPTVRelay *iptv_relay_create(uint16_t *port);
void iptv_relay_run(IPTVRelay *relay, const char *route, const char *path, const char *keys, const char *user_agent);
IPTVRelayStatus iptv_relay_status(IPTVRelay *relay);
void iptv_relay_cancel(IPTVRelay *relay);
void iptv_relay_destroy(IPTVRelay *relay);

#endif

