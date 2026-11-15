#ifndef IPTV_SOURCE_HTTP_H
#define IPTV_SOURCE_HTTP_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    void *body;
    const unsigned char *bytes;
    size_t length;
    char *location;
    int status;
    int error;
} IPTVHTTPResponse;

void *iptv_http_create(void);
void iptv_http_destroy(void *transport);
IPTVHTTPResponse iptv_http_fetch(void *transport, const char *url, const char *agent,
                                int64_t offset, int64_t end, int (*cancelled)(void *), void *context);
void iptv_http_release(IPTVHTTPResponse *response);

#endif

