//
//  SBBAuthManager.m
//  BridgeSDK
//
//  Created by Erin Mounts on 9/11/14.
//  Copyright (c) 2014 Sage Bionetworks. All rights reserved.
//

#import "SBBAuthManager.h"
#import "SBBAuthManagerInternal.h"
#import "UICKeyChainStore.h"
#import "NSError+SBBAdditions.h"
#import "SBBComponentManager.h"

NSString *gSBBAppURLPrefix = nil;

NSString *kBridgeKeychainService = @"SageBridge";
NSString *kBridgeAuthManagerFirstRunKey = @"SBBAuthManagerFirstRunCompleted";

static NSString *envSessionTokenKeyFormat[] = {
  @"SBBSessionToken-%@",
  @"SBBSessionTokenStaging-%@",
  @"SBBSessionTokenDev-%@",
  @"SBBSessionTokenCustom-%@"
};

static NSString *envUsernameKeyFormat[] = {
  @"SBBUsername-%@",
  @"SBBUsernameStaging-%@",
  @"SBBusernameDev-%@",
  @"SBBusernameCustom-%@"
};

static NSString *envPasswordKeyFormat[] = {
  @"SBBPassword-%@",
  @"SBBPasswordStaging-%@",
  @"SBBPasswordDev-%@",
  @"SBBPasswordCustom-%@"
};


dispatch_queue_t AuthQueue()
{
  static dispatch_queue_t q;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    q = dispatch_queue_create("org.sagebase.BridgeAuthQueue", DISPATCH_QUEUE_SERIAL);
  });
  
  return q;
}

// use with care--not protected. Used for serializing access to the auth manager's internal
// copy of the accountAccessToken.
void dispatchSyncToAuthQueue(dispatch_block_t dispatchBlock)
{
  dispatch_sync(AuthQueue(), dispatchBlock);
}

dispatch_queue_t KeychainQueue()
{
  static dispatch_queue_t q;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    q = dispatch_queue_create("org.sagebase.BridgeAuthKeychainQueue", DISPATCH_QUEUE_SERIAL);
  });
  
  return q;
}

// use with care--not protected. Used for serializing access to the auth credentials stored in the keychain.
// This method can be safely called from within the AuthQueue, but the provided dispatch block must
// never dispatch back to the AuthQueue either directly or indirectly, to prevent deadlocks.
void dispatchSyncToKeychainQueue(dispatch_block_t dispatchBlock)
{
  dispatch_sync(KeychainQueue(), dispatchBlock);
}


@interface SBBAuthManager()

@property (nonatomic, strong) id<SBBNetworkManagerProtocol> networkManager;
@property (nonatomic, strong) NSString *sessionToken;

+ (void)resetAuthKeychain;

- (instancetype)initWithBaseURL:(NSString *)baseURL;
- (instancetype)initWithNetworkManager:(id<SBBNetworkManagerProtocol>)networkManager;

@end

@implementation SBBAuthManager
@synthesize authDelegate = _authDelegate;
@synthesize sessionToken = _sessionToken;

+ (instancetype)defaultComponent
{
  static SBBAuthManager *shared;
  
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    id<SBBNetworkManagerProtocol> networkManager = SBBComponent(SBBNetworkManager);
    shared = [[self alloc] initWithNetworkManager:networkManager];
    [shared setupForEnvironment];
  });
  
  return shared;
}

+ (instancetype)authManagerForEnvironment:(SBBEnvironment)environment appURLPrefix:(NSString *)prefix baseURLPath:(NSString *)baseURLPath
{
  SBBNetworkManager *networkManager = [SBBNetworkManager networkManagerForEnvironment:environment appURLPrefix:gSBBAppURLPrefix baseURLPath:@"sagebridge.org"];
  SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
  [authManager setupForEnvironment];
  return authManager;
}

+ (instancetype)authManagerWithNetworkManager:(id<SBBNetworkManagerProtocol>)networkManager
{
  SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
  [authManager setupForEnvironment];
  return authManager;
}

+ (instancetype)authManagerWithBaseURL:(NSString *)baseURL
{
  id<SBBNetworkManagerProtocol> networkManager = [[SBBNetworkManager alloc] initWithBaseURL:baseURL];
  SBBAuthManager *authManager = [[self alloc] initWithNetworkManager:networkManager];
  [authManager setupForEnvironment];
  return authManager;
}

// reset the auth keychain--should be called on first access after first launch; also can be used to clear credentials for testing
+ (void)resetAuthKeychain
{
  dispatchSyncToKeychainQueue(^{
    UICKeyChainStore *store = [self sdkKeychainStore];
    [store removeAllItems];
    [store synchronize];
  });
}

// Find the bundle seed ID of the app that's using our SDK.
// Adapted from this StackOverflow answer: http://stackoverflow.com/a/11841898/931658

+ (NSString *)bundleSeedID {
  static NSString *_bundleSeedID = nil;
  
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           (__bridge id)(kSecClassGenericPassword), kSecClass,
                           @"bundleSeedID", kSecAttrAccount,
                           @"", kSecAttrService,
                           (id)kCFBooleanTrue, kSecReturnAttributes,
                           nil];
    CFDictionaryRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status == errSecItemNotFound)
      status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status == errSecSuccess) {
      NSString *accessGroup = [(__bridge NSDictionary *)result objectForKey:(__bridge id)(kSecAttrAccessGroup)];
      NSArray *components = [accessGroup componentsSeparatedByString:@"."];
      _bundleSeedID = [[components objectEnumerator] nextObject];
    }
    CFRelease(result);
  });
  
  return _bundleSeedID;
}

+ (NSString *)sdkKeychainAccessGroup
{
  return [NSString stringWithFormat:@"%@.org.sagebase.Bridge", [self bundleSeedID]];
}

+ (UICKeyChainStore *)sdkKeychainStore
{
  return [UICKeyChainStore keyChainStoreWithService:kBridgeKeychainService accessGroup:self.sdkKeychainAccessGroup];
}

- (void)setupForEnvironment
{
  if (!_authDelegate) {
    dispatchSyncToAuthQueue(^{
      _sessionToken = [self sessionTokenFromKeychain];
    });
  }
}

- (instancetype)initWithNetworkManager:(SBBNetworkManager *)networkManager
{
  if (self = [super init]) {
    _networkManager = networkManager;
    
    //Clear keychain on first run in case of reinstallation
    BOOL firstRunDone = [[NSUserDefaults standardUserDefaults] boolForKey:kBridgeAuthManagerFirstRunKey];
    if (!firstRunDone) {
      [self.class resetAuthKeychain];
      [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kBridgeAuthManagerFirstRunKey];
      [[NSUserDefaults standardUserDefaults] synchronize];
    }
  }
  
  return self;
}

- (instancetype)initWithBaseURL:(NSString *)baseURL
{
  SBBNetworkManager *networkManager = [[SBBNetworkManager alloc] initWithBaseURL:baseURL];
  if (self = [self initWithNetworkManager:networkManager]) {
    //
  }
  
  return self;
}

- (NSString *)sessionToken
{
  if (_authDelegate) {
    return [_authDelegate sessionTokenForAuthManager:self];
  } else {
    return _sessionToken;
  }
}

- (NSURLSessionDataTask *)signUpWithEmail:(NSString *)email username:(NSString *)username password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
  return [_networkManager post:@"/api/v1/auth/signUp" headers:nil parameters:@{@"email":email, @"username":username, @"password":password} completion:completion];
}

- (NSURLSessionDataTask *)signInWithUsername:(NSString *)username password:(NSString *)password completion:(SBBNetworkManagerCompletionBlock)completion
{
  return [_networkManager post:@"/api/v1/auth/signIn" headers:nil parameters:@{@"username":username, @"password":password} completion:^(NSURLSessionDataTask *task, id responseObject, NSError *error) {
    // Save session token in the keychain
    // ??? Save credentials in the keychain?
    NSString *sessionToken = responseObject[@"sessionToken"];
    if (sessionToken.length) {
      if (_authDelegate) {
        [_authDelegate authManager:self didGetSessionToken:sessionToken];
      } else {
        _sessionToken = sessionToken;
        dispatchSyncToKeychainQueue(^{
          UICKeyChainStore *store = [self.class sdkKeychainStore];
          [store setString:_sessionToken forKey:self.sessionTokenKey];
          [store setString:username forKey:self.usernameKey];
          [store setString:password forKey:self.passwordKey];
          
          [store synchronize];
        });
      }
    }
    
    if (completion) {
      completion(task, responseObject, error);
    }
  }];
}

- (NSURLSessionDataTask *)signOutWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  [self addAuthHeaderToHeaders:headers];
  return [_networkManager get:@"/api/v1/auth/signOut" headers:headers parameters:nil completion:^(NSURLSessionDataTask *task, id responseObject, NSError *error) {
    // Remove the session token (and credentials?) from the keychain
    // ??? Do we want to not do this in case of error?
    if (!_authDelegate) {
      dispatchSyncToKeychainQueue(^{
        UICKeyChainStore *store = [self.class sdkKeychainStore];
        [store removeItemForKey:self.sessionTokenKey];
        [store removeItemForKey:self.usernameKey];
        [store removeItemForKey:self.passwordKey];
        [store synchronize];
      });
      // clear the in-memory copy of the session token, too
      dispatchSyncToAuthQueue(^{
        self.sessionToken = nil;
      });
    }
    
    if (completion) {
      completion(task, responseObject, error);
    }
  }];
}

- (void)ensureSignedInWithCompletion:(SBBNetworkManagerCompletionBlock)completion
{
  if ([self isAuthenticated]) {
    if (completion) {
      completion(nil, nil, nil);
    }
  }
  else
  {
    NSString *username = nil;
    NSString *password = nil;
    if (_authDelegate) {
      if ([_authDelegate respondsToSelector:@selector(usernameForAuthManager:)] &&
          [_authDelegate respondsToSelector:@selector(passwordForAuthManager:)]) {
        username = [_authDelegate usernameForAuthManager:self];
        password = [_authDelegate passwordForAuthManager:self];
      }
    } else {
      username = [self usernameFromKeychain];
      password = [self passwordFromKeychain];
    }
    
    if (!username.length || !password.length) {
      if (completion) {
        completion(nil, nil, [NSError SBBNoCredentialsError]);
      }
    }
    else
    {
      [self signInWithUsername:username password:password completion:completion];
    }
  }
}

#pragma mark Internal helper methods

- (BOOL)isAuthenticated
{
  return (self.sessionToken.length > 0);
}

- (void)addAuthHeaderToHeaders:(NSMutableDictionary *)headers
{
  if (self.isAuthenticated) {
    [headers setObject:self.sessionToken forKey:@"Bridge-Session"];
  }
}

#pragma mark Internal keychain-related methods

- (NSString *)sessionTokenKey
{
  return [NSString stringWithFormat:envSessionTokenKeyFormat[_networkManager.environment], gSBBAppURLPrefix];
}

- (NSString *)sessionTokenFromKeychain
{
  if (!gSBBAppURLPrefix) {
    return nil;
  }
  
  __block NSString *token = nil;
  dispatchSyncToKeychainQueue(^{
    token = [[self.class sdkKeychainStore] stringForKey:[self sessionTokenKey]];
  });
  
  return token;
}

- (NSString *)usernameKey
{
  return [NSString stringWithFormat:envUsernameKeyFormat[_networkManager.environment], gSBBAppURLPrefix];
}

- (NSString *)usernameFromKeychain
{
  if (!gSBBAppURLPrefix) {
    return nil;
  }
  
  __block NSString *token = nil;
  dispatchSyncToKeychainQueue(^{
    token = [[self.class sdkKeychainStore] stringForKey:[self usernameKey]];
  });
  
  return token;
}

- (NSString *)passwordKey
{
  return [NSString stringWithFormat:envPasswordKeyFormat[_networkManager.environment], gSBBAppURLPrefix];
}

- (NSString *)passwordFromKeychain
{
  if (!gSBBAppURLPrefix) {
    return nil;
  }
  
  __block NSString *token = nil;
  dispatchSyncToKeychainQueue(^{
    token = [[self.class sdkKeychainStore] stringForKey:[self passwordKey]];
  });
  
  return token;
}

#pragma mark SDK-private methods

// used internally for unit testing
- (void)clearKeychainStore
{
  dispatchSyncToKeychainQueue(^{
    UICKeyChainStore *store = [self.class sdkKeychainStore];
    [store removeAllItems];
    [store synchronize];
  });
}

@end