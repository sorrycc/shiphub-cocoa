//
//  AvatarManager.m
//  ShipHub
//
//  Created by James Howard on 9/20/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import "AvatarManager.h"

#import "Auth.h"
#import "DataStore.h"
#import "Defaults.h"
#import "Extras.h"

#import <libkern/OSAtomic.h>

@interface AvatarManager ()

@property (copy) NSString *ghHost;
@property NSString *cachePath;
@property NSCache *cache;

@end

@implementation AvatarManager

+ (instancetype)activeManager {
    static AvatarManager *manager = nil;
    
    AvatarManager *next = manager;
    
    DataStore *store = [DataStore activeStore];
    Auth *auth = [store auth];
    AuthAccount *account = auth.account;
    NSString *ghHost = account.ghHost;
    
    if (!next || ![ghHost isEqualToString:next.ghHost]) {
        next = [[AvatarManager alloc] initWithHost:ghHost];
        manager = next;
    }
    
    return manager;
}

- (id)initWithHost:(NSString *)host {
    if (self = [super init]) {
        self.ghHost = host;
        self.cache = [NSCache new];
        
        DataStore *store = [DataStore activeStore];
        Auth *auth = [store auth];
        
        NSString *basePath = [@"~/Library/Caches/com.realartists.Ship/Images" stringByExpandingTildeInPath];
        _cachePath = [basePath stringByAppendingPathComponent:auth.account.ghHost];
        [[NSFileManager defaultManager] createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return self;
}

- (CGSize)defaultSize {
    return CGSizeMake(128, 128);
}

- (NSString *)imagePathForIdentifier:(NSNumber *)identifier {
    CGFloat w = [self defaultSize].width;
    w *= [[NSScreen mainScreen] backingScaleFactor];
    NSString *imagePath = [_cachePath stringByAppendingFormat:@"%@.%.0f.png", identifier, w];
    return imagePath;
}

- (void)checkForUpdatesToImage:(NSImage *)image identifier:(NSNumber *)identifier avatarURL:(NSURL *)avatarURL
{
    NSDate *lastChecked = [image extras_representedObject];
    if (lastChecked && [lastChecked timeIntervalSinceNow] > -300.0) {
        return; // if we checked in last 5 minutes, we're good.
    }
    image.extras_representedObject = [NSDate date];
    
    NSString *imagePath = [self imagePathForIdentifier:identifier];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:NULL];
    NSDate *lastModified = attrs[NSFileModificationDate];
    
    NSString *host = _ghHost;
    NSURL *imageURL;
    if ([host isEqualToString:@"api.github.com"]) {
        CGFloat w = [self defaultSize].width;
        w *= [[NSScreen mainScreen] backingScaleFactor];
        NSString *imageURLStr = [NSString stringWithFormat:@"https://avatars.githubusercontent.com/u/%@?v=3&s=%.0f", identifier, w];
        imageURL = [NSURL URLWithString:imageURLStr];
    } else {
        imageURL = avatarURL;
    }
    
    
    NSURLRequest *request = [NSURLRequest requestWithURL:imageURL];
    [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            ErrLog(@"%@", error);
        }
        NSHTTPURLResponse *resp = (id)response;
        NSDate *headerLastModified = [NSDate dateWithHTTPHeaderString:resp.allHeaderFields[@"Last-Modified"]];
        if (data && [resp isSuccessStatusCode] && ![NSObject object:headerLastModified isEqual:lastModified])
        {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
            if (rep) {
                [data writeToFile:imagePath atomically:YES];
                if (headerLastModified) {
                    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: headerLastModified} ofItemAtPath:imagePath error:NULL];
                }
                RunOnMain(^{
                    NSArray *existing = image.representations;
                    [image addRepresentation:rep];
                    for (NSImageRep *oldRep in existing) {
                        [image removeRepresentation:oldRep];
                    }
                });
            }
        }
    }];
}

- (void)loadImage:(NSImage *)image identifier:(NSNumber *)identifier avatarURL:(NSURL *)avatarURL {
    NSString *imagePath = [self imagePathForIdentifier:identifier];
    NSData *data = [[NSData alloc] initWithContentsOfFile:imagePath options:0 error:NULL];
    if (data) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
        if (rep) {
            [image addRepresentation:rep];
            image.extras_representedObject = [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:NULL][NSFileModificationDate];
        }
    }
}

- (NSImage *)imageForAccountIdentifier:(NSNumber *)accountIdentifier avatarURL:(NSURL *)avatarURL
{
    NSImage *image = [_cache objectForKey:accountIdentifier];
    if (!image) {
        image = [[NSImage alloc] initWithSize:[self defaultSize]];
        [_cache setObject:image forKey:accountIdentifier];
        [self loadImage:image identifier:accountIdentifier avatarURL:avatarURL];
    }
    [self checkForUpdatesToImage:image identifier:accountIdentifier avatarURL:avatarURL];
    
    return image;
}

@end