
//
//  THLine.m
//  telehash
//
//  Created by Thomas Muldowney on 11/15/13.
//  Copyright (c) 2013 Telehash Foundation. All rights reserved.
//

#import "THLine.h"
#import "THPacket.h"
#import "RNG.h"
#import "NSData+HexString.h"
#import "SHA256.h"
#import "THIdentity.h"
#import "THRSA.h"
#import "THSwitch.h"
#import "CTRAES256.h"
#import "NSString+HexString.h"
#import "THChannel.h"
#import "THMeshBuckets.h"
#import "THCipherSet.h"
#import "THPeerRelay.h"
#import "THPath.h"

#include <arpa/inet.h>

@interface THPathHandler : NSObject<THChannelDelegate>
@property THLine* line;
@end

@implementation THLine
{
    NSUInteger _nextChannelId;
    NSMutableArray* channelHandlers;
}

-(id)init;
{
    self = [super init];
    if (self) {
        channelHandlers = [NSMutableArray array];
        self.isOpen = NO;
        self.lastActitivy = time(NULL);
    }
    return self;
}

-(void)sendOpen;
{
    THSwitch* defaultSwitch = [THSwitch defaultSwitch];
    THPacket* openPacket = [defaultSwitch generateOpen:self];
    for (THPath* path in self.toIdentity.availablePaths) {
        NSLog(@"Sending open on %@ to %@", path, self.toIdentity.hashname);
        [path sendPacket:openPacket];
    }
}

-(void)handleOpen:(THPacket *)openPacket
{
    self.outLineId = [openPacket.json objectForKey:@"line"];
    self.createdAt = [[openPacket.json objectForKey:@"at"] unsignedIntegerValue];
    self.lastInActivity = time(NULL);
    if ([self.toIdentity.activePath class] == [THRelayPath class]){
        self.activePath = self.toIdentity.activePath;
    } else {
        self.activePath = openPacket.returnPath;
    }
}

-(NSUInteger)nextChannelId
{
    return _nextChannelId+=2;
}

-(void)openLine;
{
    // Do the distance calc and see if we start at 1 or 2
    THSwitch* thSwitch = [THSwitch defaultSwitch];
    if ([self.toIdentity.hashname compare:thSwitch.identity.hashname] == NSOrderedAscending) {
        _nextChannelId = 1;
    } else {
        _nextChannelId = 2;
    }
    [self.cipherSetInfo.cipherSet finalizeLineKeys:self];
    [self.toIdentity.channels enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSLog(@"Checking %@ as %@", obj, [obj class]);
        // Get all our pending reliable channels spun out
        if ([obj class] != [THReliableChannel class]) return;
        THReliableChannel* channel = (THReliableChannel*)obj;
        // If the channel already thinks it's good, we'll just ignore it's state
        if (channel.state == THChannelOpen) return;

        NSLog(@"Going to flush");
        [channel flushOut];
    }];
    
    self.isOpen = YES;
}

-(void)handlePacket:(THPacket *)packet;
{
    self.lastInActivity = time(NULL);
    self.lastActitivy = time(NULL);
    
    //NSLog(@"Going to handle a packet");
    [self.cipherSetInfo decryptLinePacket:packet];
    THPacket* innerPacket = [THPacket packetData:packet.body];
    innerPacket.returnPath = packet.returnPath;
    //NSLog(@"Packet is type %@", [innerPacket.json objectForKey:@"type"]);
    NSLog(@"Line from %@ line id %@ handling %@\n%@", self.toIdentity.hashname, self.outLineId, innerPacket.json, innerPacket.body);
    NSNumber* channelId = [innerPacket.json objectForKey:@"c"];
    NSString* channelType = [innerPacket.json objectForKey:@"type"];
    
    THSwitch* thSwitch = [THSwitch defaultSwitch];
    
    // if the switch is handling it bail
    if ([thSwitch findPendingSeek:innerPacket]) return;
    
    THChannel* channel = [self.toIdentity.channels objectForKey:channelId];
    
    if ([channelType isEqualToString:@"seek"]) {
        // On a seek we send back what we know about
        THPacket* response = [THPacket new];
        [response.json setObject:@(YES) forKey:@"end"];
        [response.json setObject:channelId forKey:@"c"];
        THSwitch* defaultSwitch = [THSwitch defaultSwitch];
        NSArray* sees = [defaultSwitch.meshBuckets closeInBucket:[THIdentity identityFromHashname:[innerPacket.json objectForKey:@"seek"]]];
        if (sees == nil) {
            sees = [NSArray array];
        }
        [response.json setObject:[sees valueForKey:@"seekString"] forKey:@"see"];
        
        [self sendPacket:response];
    } else if ([channelType isEqualToString:@"link"] && !channel) {
        THSwitch* defaultSwitch = [THSwitch defaultSwitch];
        
        [defaultSwitch.meshBuckets addIdentity:self.toIdentity];
        
        THUnreliableChannel* linkChannel = [[THUnreliableChannel alloc] initToIdentity:self.toIdentity];
        linkChannel.channelId = [innerPacket.json objectForKey:@"c"];
        linkChannel.type = @"link";
        linkChannel.delegate = defaultSwitch.meshBuckets;
        
        THUnreliableChannel* curChannel = (THUnreliableChannel*)[self.toIdentity channelForType:@"link"];
        if (curChannel) {
            [self.toIdentity.channels removeObjectForKey:curChannel.channelId];
        }
        [defaultSwitch openChannel:linkChannel firstPacket:nil];
        [defaultSwitch.meshBuckets channel:linkChannel handlePacket:innerPacket];
    } else if ([channelType isEqualToString:@"peer"]) {
        // TODO:  Check this logic in association with the move to channels on identity
        THLine* peerLine = [thSwitch lineToHashname:[innerPacket.json objectForKey:@"peer"]];
        if (!peerLine) {
            // What? We don't know about this person, bye bye
            return;
        }
        
        THPacket* connectPacket = [THPacket new];
        [connectPacket.json setObject:@"connect" forKey:@"type"];
        [connectPacket.json setObject:self.toIdentity.parts forKey:@"from"];
        NSArray* paths = [innerPacket.json objectForKey:@"paths"];
        if (paths) {
            // XXX FIXME check if we know any other paths
            [connectPacket.json setObject:paths forKey:@"paths"];
        }
        connectPacket.body = innerPacket.body;

        THPeerRelay* relay = [THPeerRelay new];
        
        THUnreliableChannel* connectChannel = [[THUnreliableChannel alloc] initToIdentity:peerLine.toIdentity];
        connectChannel.delegate = relay;
        THUnreliableChannel* peerChannel = [[THUnreliableChannel alloc] initToIdentity:self.toIdentity];
        peerChannel.channelId = [innerPacket.json objectForKey:@"c"];
        peerChannel.delegate = relay;
        [thSwitch openChannel:peerChannel firstPacket:nil];

        relay.connectChannel = connectChannel;
        relay.peerChannel = peerChannel;
        
        [thSwitch openChannel:connectChannel firstPacket:connectPacket];
        // XXX FIXME TODO: check the connect channel timeout for going away?
    } else if ([channelType isEqualToString:@"connect"]) {
        // XXX FIXME TODO: Find the correct cipher set here
        THCipherSet2a* cs = [[THCipherSet2a alloc] initWithPublicKey:innerPacket.body privateKey:nil];
        THIdentity* peerIdentity = [THIdentity identityFromParts:[innerPacket.json objectForKey:@"from"] key:cs];
        if (!peerIdentity) {
            // We couldn't verify the identity, so shut it down
            THPacket* closePacket = [THPacket new];
            [closePacket.json setObject:@YES forKey:@"end"];
            [closePacket.json setObject:[innerPacket.json objectForKey:@"c"] forKey:@"c"];
            
            [packet.returnPath sendPacket:closePacket];
            return;
        }
        
        // Add the available paths
        NSArray* paths = [innerPacket.json objectForKey:@"paths"];
        for (NSDictionary* pathInfo in paths) {
            if ([[pathInfo objectForKey:@"type"] isEqualToString:@"ipv4"]) {
                THIPV4Path* newPath = [[THIPV4Path alloc] initWithTransport:packet.returnPath.transport ip:[pathInfo objectForKey:@"ip"] port:[[pathInfo objectForKey:@"port"] unsignedIntegerValue]];
                [peerIdentity addPath:newPath];
            }
        }
        
        THUnreliableChannel* peerChannel = [[THUnreliableChannel alloc] initToIdentity:self.toIdentity];
        peerChannel.channelId = [innerPacket.json objectForKey:@"c"];
        [thSwitch openChannel:peerChannel firstPacket:nil];
        
        THRelayPath* relayPath = [THRelayPath new];
        relayPath.relayedPath = packet.returnPath;
        relayPath.transport = packet.returnPath.transport;
        relayPath.peerChannel = peerChannel;
        peerChannel.delegate = relayPath;
        
        [peerIdentity.availablePaths addObject:relayPath];
        if (!peerIdentity.activePath) peerIdentity.activePath = relayPath;
        
        [thSwitch openLine:peerIdentity];
    } else if ([channelType isEqualToString:@"path"] && !channel) {
        if ([[innerPacket.json objectForKey:@"priority"] integerValue] == 1) {
            // This came in on the new path we want to use!
            self.toIdentity.activePath = packet.returnPath;
            self.activePath = packet.returnPath;
        }
        THPacket* pathPacket = [THPacket new];
        [pathPacket.json setObject:[thSwitch.identity pathInformation] forKey:@"paths"];
        [pathPacket.json setObject:@YES forKey:@"end"];
        [pathPacket.json setObject:[innerPacket.json objectForKey:@"c"] forKey:@"c"];
        NSDictionary* returnPathInfo = [packet.returnPath information];
        if (returnPathInfo) {
            [pathPacket.json setObject:returnPathInfo forKey:@"path"];
        }
        
        if (packet.returnPath.transport.priority > 0) {
            [pathPacket.json setObject:@(packet.returnPath.transport.priority) forKey:@"priority"];
        }
        [self.toIdentity sendPacket:pathPacket path:packet.returnPath];
    } else {
        NSNumber* seq = [innerPacket.json objectForKey:@"seq"];
        // Let the channel instance handle it
        if (channel) {
            if (seq) {
                // This is a reliable channel, let's make sure we're in a good state
                THReliableChannel* reliableChannel = (THReliableChannel*)channel;
                if (seq.unsignedIntegerValue == 0 && [[innerPacket.json objectForKey:@"ack"] unsignedIntegerValue] == 0) {
                    reliableChannel.state = THChannelOpen;
                }
            }
            [channel handlePacket:innerPacket];
        } else {
            // See if it's a reliable or unreliable channel
            if (!channelType) {
                THPacket* errPacket = [THPacket new];
                [errPacket.json setObject:@"Unknown channel packet type." forKey:@"err"];
                [errPacket.json setObject:channelId forKey:@"c"];
                
                [self.toIdentity sendPacket:errPacket];
                return;
            }
            THChannel* newChannel;
            THChannelType newChannelType;
            if (seq && [seq unsignedIntegerValue] == 0) {
                newChannel = [[THReliableChannel alloc] initToIdentity:self.toIdentity];
                newChannelType = ReliableChannel;
            } else {
                newChannel = [[THUnreliableChannel alloc] initToIdentity:self.toIdentity];
                newChannelType = UnreliableChannel;
            }
            newChannel.channelId = channelId;
            // Opening state for initial processing
            newChannel.state = THChannelOpening;
            newChannel.type = channelType;
            THSwitch* defaultSwitch = [THSwitch defaultSwitch];
            NSLog(@"Adding a channel");
            [self.toIdentity.channels setObject:newChannel forKey:channelId];
            [newChannel handlePacket:innerPacket];
            // Now we're full open and ready to roll
            newChannel.state = THChannelOpen;
            if ([defaultSwitch.delegate respondsToSelector:@selector(channelReady:type:firstPacket:)]) {
                [defaultSwitch.delegate channelReady:newChannel type:newChannelType firstPacket:innerPacket];
            }
        }
        
    }
}

-(void)sendPacket:(THPacket *)packet path:(THPath*)path
{
    self.lastOutActivity = time(NULL);
    NSLog(@"Sending %@\%@", packet.json, packet.body);
    NSData* innerPacketData = [self.cipherSetInfo encryptLinePacket:packet];
    NSMutableData* linePacketData = [NSMutableData dataWithCapacity:(innerPacketData.length + 16)];
    [linePacketData appendData:[self.outLineId dataFromHexString]];
    [linePacketData appendData:innerPacketData];
    THPacket* lineOutPacket = [THPacket new];
    lineOutPacket.body = linePacketData;
    lineOutPacket.jsonLength = 0;
    
    if (path == nil) path = self.activePath;
    [path sendPacket:lineOutPacket];
}

-(void)sendPacket:(THPacket *)packet;
{
    [self sendPacket:packet path:nil];
}

-(void)close
{
    [[THSwitch defaultSwitch] closeLine:self];
}

-(void)negotiatePath
{
    THSwitch* thSwitch = [THSwitch defaultSwitch];
    
    for (THPath* path in self.toIdentity.availablePaths) {

        THUnreliableChannel* pathChannel = [[THUnreliableChannel alloc] initToIdentity:self.toIdentity];
        
        THPathHandler* handler = [THPathHandler new];
        handler.line = self;
        pathChannel.delegate = handler;
        pathChannel.type = @"path";
        
        [self addChannelHandler:handler];

        THPacket* pathPacket = [THPacket new];
        NSDictionary* info = path.information;
        if (info) [pathPacket.json setObject:path.information forKey:@"path"];
        [pathPacket.json setObject:[thSwitch.identity pathInformation] forKey:@"paths"];
        [pathPacket.json setObject:@"path" forKey:@"type"];
        if (![path.typeName isEqualToString:@"relay"] && path.transport.priority > 0) {
            [pathPacket.json setObject:@(path.transport.priority) forKey:@"priority"];
        }
        /*
        NSDictionary* returnPathInfo = [pathPacket.returnPath information];
        if (returnPathInfo) {
            [pathPacket.json setObject:returnPathInfo forKey:@"path"];
        }
         */
        [thSwitch openChannel:pathChannel firstPacket:nil];
        [pathPacket.json setObject:pathChannel.channelId forKey:@"c"];
        
        NSLog(@"Sending a path negotiation over %@: %@", path.information, pathPacket.json);
        [self sendPacket:pathPacket path:path];
        //[self.toIdentity sendPacket:pathPacket path:packet.returnPath];
    }
}

-(void)addChannelHandler:(id)handler
{
    [channelHandlers addObject:handler];
}

-(void)removeChannelHandler:(id)handler
{
    [channelHandlers removeObject:handler];
}
@end

@implementation THPathHandler

-(BOOL)channel:(THChannel *)channel handlePacket:(THPacket *)packet
{

    NSUInteger priority = [[packet.json objectForKey:@"priority"] unsignedIntegerValue];
    for (NSDictionary* ipInfo in [packet.json objectForKey:@"paths"]) {
        if ([[ipInfo objectForKey:@"type"] isEqualToString:@"ipv4"] && priority > 0) {
            THIPV4Path* newPath = [[THIPV4Path alloc] initWithTransport:packet.returnPath.transport ip:[ipInfo objectForKey:@"ip"] port:[[ipInfo objectForKey:@"port"] unsignedIntegerValue]];
                
            [self.line.toIdentity.availablePaths insertObject:newPath atIndex:0];
            self.line.toIdentity.activePath = newPath;
            self.line.activePath = newPath;
        }
    }
    
    [self.line removeChannelHandler:self];
    
    return YES;
}

-(void)channel:(THChannel *)channel didChangeStateTo:(THChannelState)channelState
{
}

-(void)channel:(THChannel *)channel didFailWithError:(NSError *)error
{
}

@end