//
//  THRelay.h
//  telehash
//
//  Created by Thomas Muldowney on 5/17/14.
//  Copyright (c) 2014 Telehash Foundation. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "THChannel.h"
#import "THUnreliableChannel.h"
#import "THPath.h"

@interface THRelay : NSObject<THChannelDelegate>
@property (nonatomic, assign) THIdentity* toIdentity;
@property (nonatomic, retain) THPath* relayedPath;
@property (nonatomic, assign) THUnreliableChannel* peerChannel;
-(id)initOnChannel:(THUnreliableChannel*)channel;
-(void)sendPacket:(THPacket *)packet;
@end