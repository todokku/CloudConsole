//
//  CCOServer.h
//  CloudConsole
//
//  Created by Will Cobb on 1/5/16.
//  Copyright © 2016 Will Cobb. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "CCUdpSocket.h"
#import "CCOVideoStream.h"


@interface CCOServer : NSObject <CCUdpSocketDelegate, CCVideoStreamDelegate>

@property NSString *deviceName;

+ (id)sharedInstance;
- (void)start;
- (uint16_t)currentPort;
- (NSString *)currentIP;
- (void)registerDelegate:(id <CCUdpSocketDelegate>) delegate forBuffer:(uint32_t)bufferTag;


@end
