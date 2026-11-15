#import "SourceHTTP.h"
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

static const NSUInteger maximumResourceBytes = 32 * 1024 * 1024;

@interface IPTVHTTPTransport : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) dispatch_semaphore_t finished;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSHTTPURLResponse *response;
@property(nonatomic) NSInteger error;
@end

@implementation IPTVHTTPTransport

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 10;
        config.timeoutIntervalForResource = 15;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        self.error = NSURLErrorBadServerResponse;
        completion(NSURLSessionResponseCancel);
        return;
    }
    self.response = (NSHTTPURLResponse *)response;
    if (self.response.statusCode < 200 || self.response.statusCode >= 300) {
        completion(NSURLSessionResponseCancel);
        return;
    }
    if (response.expectedContentLength > (int64_t)maximumResourceBytes) {
        self.error = NSURLErrorDataLengthExceedsMaximum;
        completion(NSURLSessionResponseCancel);
        return;
    }
    completion(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > maximumResourceBytes - self.data.length) {
        self.error = NSURLErrorDataLengthExceedsMaximum;
        [task cancel];
        return;
    }
    [self.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.error == 0 && error) self.error = error.code;
    dispatch_semaphore_signal(self.finished);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    NSString *scheme = request.URL.scheme.lowercaseString;
    BOOL isHTTP = [scheme isEqualToString:@"http"];
    BOOL isHTTPS = [scheme isEqualToString:@"https"];
    BOOL downgrade = isHTTP && [response.URL.scheme.lowercaseString isEqualToString:@"https"];
    if ((!isHTTP && !isHTTPS) || downgrade) {
        completion(nil);
        return;
    }
    NSMutableURLRequest *redirect = [request mutableCopy];
    for (NSString *field in @[@"User-Agent", @"Range", @"Accept-Encoding"]) {
        [redirect setValue:[task.originalRequest valueForHTTPHeaderField:field] forHTTPHeaderField:field];
    }
    completion(redirect);
}

@end

void *iptv_http_create(void) {
    return (__bridge_retained void *)[[IPTVHTTPTransport alloc] init];
}

void iptv_http_destroy(void *opaque) {
    IPTVHTTPTransport *transport = (__bridge_transfer IPTVHTTPTransport *)opaque;
    [transport.session invalidateAndCancel];
}

IPTVHTTPResponse iptv_http_fetch(void *opaque, const char *url, const char *agent,
                                int64_t offset, int64_t end, int (*cancelled)(void *), void *context) {
    @autoreleasepool {
        IPTVHTTPResponse result = {0};
        IPTVHTTPTransport *transport = (__bridge IPTVHTTPTransport *)opaque;
        NSString *address = [NSString stringWithUTF8String:url];
        NSURL *source = address ? [NSURL URLWithString:address] : nil;
        if (!source.host.length || offset < 0 || (end > 0 && end <= offset)) {
            result.error = NSURLErrorBadURL;
            return result;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:source];
        if (agent && *agent) {
            [request setValue:[NSString stringWithUTF8String:agent] forHTTPHeaderField:@"User-Agent"];
        }
        BOOL range = offset > 0 || end > 0;
        if (range) {
            NSString *value = end > 0
                ? [NSString stringWithFormat:@"bytes=%lld-%lld", (long long)offset, (long long)(end - 1)]
                : [NSString stringWithFormat:@"bytes=%lld-", (long long)offset];
            [request setValue:value forHTTPHeaderField:@"Range"];
            [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        }

        transport.finished = dispatch_semaphore_create(0);
        transport.data = [NSMutableData data];
        transport.response = nil;
        transport.error = 0;
        NSURLSessionDataTask *task = [transport.session dataTaskWithRequest:request];
        [task resume];
        while (dispatch_semaphore_wait(transport.finished, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
            if (cancelled(context)) {
                [task cancel];
                dispatch_semaphore_wait(transport.finished, DISPATCH_TIME_FOREVER);
                break;
            }
        }

        NSHTTPURLResponse *response = transport.response;
        result.status = (int)response.statusCode;
        result.error = (int)transport.error;
        if (result.error || result.status < 200 || result.status >= 300) return result;

        NSUInteger first = 0;
        NSUInteger count = transport.data.length;
        if (range && result.status == 206) {
            NSString *contentRange = [response valueForHTTPHeaderField:@"Content-Range"];
            long long firstByte, lastByte;
            if (!contentRange || sscanf(contentRange.UTF8String, "bytes %lld-%lld/", &firstByte, &lastByte) != 2 ||
                firstByte != offset || lastByte < firstByte ||
                (end > 0 && lastByte >= end) || (uint64_t)(lastByte - firstByte) + 1 != count) {
                result.error = NSURLErrorCannotParseResponse;
                return result;
            }
        } else if (range) {
            if ((uint64_t)offset >= count) {
                result.error = NSURLErrorCannotParseResponse;
                return result;
            }
            first = (NSUInteger)offset;
            count -= first;
            if (end > 0 && (uint64_t)(end - offset) < count) count = (NSUInteger)(end - offset);
        }

        NSData *body = transport.data;
        result.body = (__bridge_retained void *)body;
        result.bytes = count ? (const unsigned char *)body.bytes + first : NULL;
        result.length = count;
        result.location = response.URL.absoluteString.UTF8String ? strdup(response.URL.absoluteString.UTF8String) : NULL;
        transport.data = nil;
        return result;
    }
}

void iptv_http_release(IPTVHTTPResponse *response) {
    if (response->body) CFRelease(response->body);
    free(response->location);
}

