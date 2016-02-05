//
//  CCUdpSocket.m
//  CloudConsole
//
//  Created by Will Cobb on 1/13/16.
//  Copyright © 2016 Will Cobb. All rights reserved.
//

#import "CCUdpSocket.h"
#import "CCNetworkProtocol.h"
#import "CCUdpBuffer.h"
#import <QuartzCore/QuartzCore.h> //For CACurrentMediaTime

@interface GCDAsyncUdpSocket ()

- (void)notifyDidReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)context;
- (void)notifyDidConnectToAddress:(NSData *)anAddress;
- (void)notifyDidCloseWithError:(NSError *)error;
@end

@interface CCUdpSocket () {
    NSString    *host;
    uint16_t    port;
    CFTimeInterval  lastKeepAlive;
    BOOL        sendingKeepAlives;
    uint16_t    boundPort;
    NSInteger   timeout;
    
    int         wrongStateCount;
    
    NSMutableDictionary *buffers;
}

@end

@implementation CCUdpSocket

- (id)initWithDelegate:(id <CCUdpSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq
{
    if (self = [super initWithDelegate:aDelegate delegateQueue:dq]) {
        lastKeepAlive = 0;
        wrongStateCount = 0;
        self.applicationState = CCStateHome;
        buffers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setDestinationHost:(NSString *)aHost port:(uint16_t)aPort
{
    host = aHost;
    port = aPort;
    [self reset];
}

- (void)reset
{
    wrongStateCount = 0;
    timeout = 20;
    lastKeepAlive = CACurrentMediaTime();
    [self startSendingKeepAlives];
}

- (void)sendData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
    NSLog(@"Error, using wrong send");
    //crash
    int *x;
    *x = 42;
}

- (void)sendData:(NSData *)data withTimeout:(NSTimeInterval)atimeout CCtag:(uint32_t)tag
{
    [self sendData:data toHost:host port:port withTimeout:atimeout CCtag:tag];
}

- (void)sendData:(NSData *)data toHost:(NSString *)ahost port:(uint16_t)aport withTimeout:(NSTimeInterval)atimeout CCtag:(uint32_t)tag
{
    //NSLog(@"Sending Data");
    // Consider adding HMAC
    //Chunk the data
    //NSLog(@"Send Data");
    NSUInteger length = data.length;
    NSUInteger offset = 0;
    uint32_t currentBlock = 0;
    uint32_t numberOfBlocks = (uint32_t)data.length/CCNetworkUDPDataSize + 1;
    NSMutableData * chunk;
    do {
        NSUInteger thisChunkSize = length - offset > CCNetworkUDPDataSize ? CCNetworkUDPDataSize : length - offset;
        if (currentBlock == 0) {
            uint32_t header[4] = {tag, CCNetworkStreamBeginBlock, numberOfBlocks, (uint32_t)length};
            chunk = [[NSMutableData alloc] initWithLength:thisChunkSize + 16];
            [chunk replaceBytesInRange:NSMakeRange(0, 16) withBytes:header];
            [chunk replaceBytesInRange:NSMakeRange(16, thisChunkSize) withBytes:data.bytes + offset];
        } else {
            uint32_t header[3] = {tag, CCNetworkStreamBlockNumber, currentBlock};
            chunk = [[NSMutableData alloc] initWithLength:thisChunkSize + 12];
            [chunk replaceBytesInRange:NSMakeRange(0, 12) withBytes:header];
            [chunk replaceBytesInRange:NSMakeRange(12, thisChunkSize) withBytes:data.bytes + offset];
        }
        
        offset += thisChunkSize;
        [super sendData:chunk toHost:ahost port:aport withTimeout:atimeout tag:0];
        currentBlock++;
    } while (offset < length);
    
    if (!self.connected) {
        NSLog(@"Sending data to non-connected socket");
        //Maybe notify did not send data
        return;
    }
    
    if (self.localPort != 0 && self.localPort != boundPort) {
        NSError *err;
        [self beginReceiving:&err];
        if (err) {
            NSLog(@"Couldn't begin receiving: %@", err);
        }
        boundPort = self.localPort;
    }
}

- (BOOL)connected
{
    if (CACurrentMediaTime() - lastKeepAlive > timeout) {
        NSLog(@"Udp Socket Disconnected");
        NSError * error = [NSError errorWithDomain:@"com.WilliamLCobb.CloudConsole" code:-12 userInfo:[NSDictionary dictionaryWithObject:@"Socket failed to respond" forKey:NSLocalizedDescriptionKey]];
        [self notifyDidCloseWithError:error];
        return NO;
    }
    return YES;
}

- (void)startSendingKeepAlives
{
    if (!self.connected || sendingKeepAlives) {
        return;
    }
    sendingKeepAlives = YES;
    [self sendKeepAlives];
}

- (void)sendKeepAlives
{
    //NSLog(@"Sending Keep Alive");
    if (host.length != 0) {
        [self sendData:[NSData dataWithBytes:&_applicationState length:4] withTimeout:-1 CCtag:CCNetworkStreamKeepAlive];
    }
    if (!self.connected) {
        NSLog(@"Stopping keep alive 1");
        sendingKeepAlives = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendKeepAlives];
    });
}

- (void)pingHost:(NSString *)aHost port:(uint16_t)aPort
{
    [self sendData:[NSData data] toHost:aHost port:aPort withTimeout:-1 CCtag:CCNetworkPing];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Delegate Helpers
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)notifyDidReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)context
{
    if (CACurrentMediaTime() - lastKeepAlive > 10) { //Not connected
        [self notifyDidConnectToAddress:address];
    }
    uint32_t *message = (uint32_t*)data.bytes;
    uint32_t tag = message[0];
    switch (tag) {
        case CCNetworkStreamKeepAlive: {
            //NSLog(@"Got keep alive");
            if (message[4] != self.applicationState) {
                wrongStateCount++;
                if (wrongStateCount == 3) {
                    NSLog(@"Warning, socket is in a different state");
                    NSLog(@"Me: %u them: %u", self.applicationState, message[4]);
                    [self.delegate performSelectorOnMainThread:@selector(wrongApplicationState) withObject:nil waitUntilDone:NO];
                }
            } else {
                wrongStateCount = 0;
                timeout = 10;
            }
            break;
        }
        default:
        {
            NSString *tagString = [NSString stringWithFormat:@"%u", tag];
            if (!buffers[tagString]) {
                NSLog(@"Creating Buffer: %@", tagString);
                [buffers setObject:[CCUdpBuffer bufferWithTag:tag] forKey:tagString];
            }
            CCUdpBuffer *buffer = buffers[tagString];
            NSData *bufferData = [buffer consumeData:[NSData dataWithBytesNoCopy:(uint8_t*)data.bytes+4 length:data.length-4 freeWhenDone:NO]];
            if (bufferData) {
                [self notifyDidReceiveData:bufferData fromAddress:address withTag:tag];
            }
            break;
        }
    }
    
    lastKeepAlive = CACurrentMediaTime();
    if (host.length == 0) { //Connect
        [self setDestinationHost:[GCDAsyncSocket hostFromAddress:address] port:[GCDAsyncSocket portFromAddress:address]];
        [self notifyDidConnectToAddress:address];
    }
    //Server socket changed port
    if ([host isEqualToString:[GCDAsyncSocket hostFromAddress:address]] && port != [GCDAsyncSocket portFromAddress:address]) {
        NSLog(@"Changing Socket port to: %d", [GCDAsyncSocket portFromAddress:address]);
        [self setDestinationHost:[GCDAsyncSocket hostFromAddress:address] port:[GCDAsyncSocket portFromAddress:address]];
    }
}

- (void)notifyDidReceiveData:(NSData *)data fromAddress:(NSData *)address withTag:(uint32_t)tag
{
    SEL selector = @selector(CCSocket:didReceiveData:fromAddress:withTag:);
    
    if (self.delegateQueue && [self.delegate respondsToSelector:selector])
    {
        id theDelegate = self.delegate;
        dispatch_async(self.delegateQueue, ^{
            [theDelegate CCSocket:self didReceiveData:data fromAddress:address withTag:tag];
        });
    } else {
        NSLog(@"Warining, CCUdpSocket not notifying");
    }
}

@end
