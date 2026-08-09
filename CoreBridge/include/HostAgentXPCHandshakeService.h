#ifndef HOST_AGENT_XPC_HANDSHAKE_SERVICE_H
#define HOST_AGENT_XPC_HANDSHAKE_SERVICE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol RDNHostAgentXPCHandshakeService
- (void)performHandshakeWithRequestData:(NSData *)requestData
                                  reply:(void (^)(NSData * _Nullable responseData))reply
    NS_SWIFT_NAME(performHandshake(requestData:reply:));
@end

/// Snapshot-first extension used only after the inherited handshake has
/// negotiated a compatible wire version on the same XPC connection.
@protocol RDNHostAgentXPCSnapshotService <RDNHostAgentXPCHandshakeService>
- (void)fetchSnapshotWithRequestData:(NSData *)requestData
                               reply:(void (^)(NSData * _Nullable responseData))reply
    NS_SWIFT_NAME(fetchSnapshot(requestData:reply:));
@end

/// Cursor-based event extension. The same connection must complete a
/// compatible handshake and successfully fetch a snapshot before use.
@protocol RDNHostAgentXPCEventService <RDNHostAgentXPCSnapshotService>
- (void)fetchEventsWithRequestData:(NSData *)requestData
                             reply:(void (^)(NSData * _Nullable responseData))reply
    NS_SWIFT_NAME(fetchEvents(requestData:reply:));
@end

/// Data-only semantic command extension. The same connection must complete a
/// compatible handshake and successfully fetch a snapshot before use.
@protocol RDNHostAgentXPCCommandService <RDNHostAgentXPCEventService>
- (void)submitCommandWithRequestData:(NSData *)requestData
                               reply:(void (^)(NSData * _Nullable responseData))reply
    NS_SWIFT_NAME(submitCommand(requestData:reply:));
@end

NS_ASSUME_NONNULL_END

#endif
