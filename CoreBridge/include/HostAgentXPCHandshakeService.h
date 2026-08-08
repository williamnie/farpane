#ifndef HOST_AGENT_XPC_HANDSHAKE_SERVICE_H
#define HOST_AGENT_XPC_HANDSHAKE_SERVICE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol RDNHostAgentXPCHandshakeService
- (void)performHandshakeWithRequestData:(NSData *)requestData
                                  reply:(void (^)(NSData * _Nullable responseData))reply
    NS_SWIFT_NAME(performHandshake(requestData:reply:));
@end

NS_ASSUME_NONNULL_END

#endif
