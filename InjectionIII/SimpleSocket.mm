//
//  SimpleSocket.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//

#import "SimpleSocket.h"

#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netdb.h>
#import <ifaddrs.h>

@implementation SimpleSocket

+ (int)error:(NSString *)message {
    NSLog(message, strerror(errno));
    return -1;
}

+ (void)startServer:(NSString *)address {
    [self performSelectorInBackground:@selector(runServer:) withObject:address];
}

+ (void)runServer:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int serverSocket = [self newSocket:serverAddr.ss_family];
    if (serverSocket < 0)
        return;

    if (bind(serverSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0)
        [self error:@"Could not bind service socket: %s"];
    else if (listen(serverSocket, 5) < 0)
        [self error:@"Service socket would not listen: %s"];
    else
        while (TRUE) {
            struct sockaddr_storage clientAddr;
            socklen_t addrLen = sizeof clientAddr;

            int clientSocket = accept(serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
            if (clientSocket > 0) {
                @autoreleasepool {
                    struct sockaddr_in *v4Addr = (struct sockaddr_in *)&clientAddr;
                    NSLog(@"Connection from %s:%d\n",
                          inet_ntoa(v4Addr->sin_addr), ntohs(v4Addr->sin_port));
                    [[[self alloc] initSocket:clientSocket] run];
                }
            }
            else
                [NSThread sleepForTimeInterval:.5];
        }
}

+ (instancetype)connectTo:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int clientSocket = [self newSocket:serverAddr.ss_family];
    if (clientSocket < 0)
        return nil;

    if (connect(clientSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0) {
        [self error:@"Could not connect: %s"];
        return nil;
    }

    return [[self alloc] initSocket:clientSocket];
}

+ (int)newSocket:(sa_family_t)addressFamily {
    int optval = 1, newSocket;
    if ((newSocket = socket(addressFamily, SOCK_STREAM, 0)) < 0)
        [self error:@"Could not open service socket: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof optval) < 0)
        [self error:@"Could not set SO_REUSEADDR: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set SO_NOSIGPIPE: %s"];
    else if (setsockopt(newSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set TCP_NODELAY: %s"];
    else
        return newSocket;
    return -1;
}

/**
 * Available formats
 * @"<host>[:<port>]"
 * where <host> can be NNN.NNN.NNN.NNN or hostname, empty for localhost or * for all interfaces
 * The default port is 80 or a specific number to bind or an empty string to allocate any port
 */
+ (BOOL)parseV4Address:(NSString *)address into:(struct sockaddr_storage *)serverAddr {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@":"];

    struct sockaddr_in *v4Addr = (struct sockaddr_in *)serverAddr;
    bzero(v4Addr, sizeof *v4Addr);

    v4Addr->sin_family = AF_INET;
    v4Addr->sin_len = sizeof *v4Addr;
    v4Addr->sin_port = htons(parts.count > 1 ? parts[1].intValue : 80);

    const char *host = parts[0].UTF8String;

    if (!host[0])
        v4Addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (host[0] == '*')
        v4Addr->sin_addr.s_addr = htonl(INADDR_ANY);
    else if (isdigit(host[0]))
        v4Addr->sin_addr.s_addr = inet_addr(host);
    else if (struct hostent *hp = gethostbyname2(host, v4Addr->sin_family))
        memcpy((void *)&v4Addr->sin_addr, hp->h_addr, hp->h_length);
    else {
        [self error:[NSString stringWithFormat:@"Unable to look up host for %@", address]];
        return FALSE;
    }

    return TRUE;
}

// Get IP Address
+ (nullable NSString *)getIPAddress {
    NSString *ret = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    // retrieve the current interfaces - returns 0 on success
    success = getifaddrs(&interfaces);
    if (success == 0) {
        // Loop through linked list of interfaces
        NSMutableDictionary *addrDic = [NSMutableDictionary dictionary];
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check if interface is en0 which is the wifi connection on the iPhone
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if([name hasPrefix:@"en"]) {
                    // Get NSString from C String
                    NSString *address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    [addrDic setObject:address ?: @"" forKey:name];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        
        NSArray *names = [addrDic.allKeys sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            return ([[obj1 substringFromIndex:2] integerValue] >
                    [[obj2 substringFromIndex:2] integerValue]) ? NSOrderedDescending : NSOrderedAscending;
        }];
        for (NSString *name in names) {
            if ([self isValidIPAddress:addrDic[name]]) {
                ret = addrDic[name];
                break;
            }
        }
    }
    // Free memory
    freeifaddrs(interfaces);
    return ret;
}

+ (BOOL)isValidIPAddress:(NSString *)address {
    const char *utf8 = [address UTF8String];
    int success;

    struct in_addr dst;
    success = inet_pton(AF_INET, utf8, &dst);
    if (success != 1) {
        struct in6_addr dst6;
        success = inet_pton(AF_INET6, utf8, &dst6);
    }

    return success == 1;
}

- (instancetype)initSocket:(int)socket {
    if ((self = [super init])) {
        clientSocket = socket;
    }
    return self;
}

- (void)run {
    [self performSelectorInBackground:@selector(runInBackground) withObject:nil];
}

- (void)runInBackground {
    [[self class] error:@"-[Networking run] not implemented in subclass"];
}

- (int)readInt {
    int32_t anint;
    if (read(clientSocket, &anint, sizeof anint) != sizeof anint)
        return ~0;
    return anint;
}

- (NSString *)readString {
    uint32_t length = [self readInt];
    if (length == ~0)
        return nil;
    char *utf8 = (char *)malloc(length + 1);
    uint32_t readLength = 0;
    while ((readLength += read(clientSocket, utf8 + readLength, length - readLength)) != length);
    utf8[length] = '\000';
    return [NSString stringWithUTF8String:utf8];
}

- (BOOL)writeString:(NSString *)string {
    const char *utf8 = string.UTF8String;
    uint32_t length = (uint32_t)strlen(utf8);
    if (write(clientSocket, &length, sizeof length) != sizeof length ||
        write(clientSocket, utf8, length) != length)
        return FALSE;
    return TRUE;
}

- (BOOL)writeCommand:(int)command withString:(NSString *)string {
    return write(clientSocket, &command, sizeof command) == sizeof command &&
        (!string || [self writeString:string]);
}

- (NSData *_Nullable)readData {
    uint32_t length = [self readInt];
    if (length == ~0)
        return nil;
    uint8_t *buf = (uint8_t *)malloc(length);
    uint32_t readLength = 0;
    while ((readLength += read(clientSocket, buf + readLength, length - readLength)) != length);
    NSData *data = [NSData dataWithBytes:buf length:length];
    free(buf);
    return data;
}

- (BOOL)writeData:(NSData *_Nonnull)data {
    const uint8_t *buf = (const uint8_t *)data.bytes;
    uint32_t length = (uint32_t)data.length;
    if (write(clientSocket, &length, sizeof length) != sizeof length ||
        write(clientSocket, buf, length) != length)
        return FALSE;
    return TRUE;
}

- (void)dealloc {
    close(clientSocket);
}

@end
