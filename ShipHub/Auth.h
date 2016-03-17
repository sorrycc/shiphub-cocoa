//
//  Auth.h
//  ShipHub
//
//  Created by James Howard on 2/24/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "JSONItem.h"

@class ServerConnection;

@interface AuthAccount : NSObject <JSONItem>

@property (copy) NSString *login;
@property (copy) NSString *name;
@property (strong) NSNumber *ghIdentifier;
@property (strong) NSString *shipIdentifier;

@property (copy) NSString *ghHost;
@property (copy) NSString *shipHost;

@property (strong) NSDictionary *extra;

@end

typedef NS_ENUM(NSInteger, AuthState) {
    AuthStateInvalid,
    AuthStateValid
};

@interface Auth : NSObject

+ (NSArray<NSString *> *)allLogins;
+ (NSString *)lastUsedLogin;

// Load an existing account by name from the keychain
+ (Auth *)authWithLogin:(NSString *)login;

// Add a new account and token to the keychain
+ (Auth *)authWithAccount:(AuthAccount *)account shipToken:(NSString *)shipToken ghToken:(NSString *)ghToken;

@property (readonly, strong) AuthAccount *account;
@property (readonly, copy) NSString *token;
@property (readonly, copy) NSString *ghToken;

@property (readonly) AuthState authState;

- (void)invalidate; // Call if the server has indicated that our token has become invalid

- (BOOL)checkResponse:(NSURLResponse *)response; // invalidate if response code is HTTP 401. Returns YES if not invalidated.
- (BOOL)checkError:(NSError *)error; // invalidate if error is ShipErrorCodeNeedsAuthToken. Returns YES if not invalidated.

- (void)logout;

@end

extern NSString *const AuthStateChangedNotification;
extern NSString *const AuthStateKey;
extern NSString *const AuthStatePreviousKey;
