//
//  LocalIssue.m
//  ShipHub
//
//  Created by James Howard on 3/14/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import "LocalIssue.h"
#import "LocalMilestone.h"
#import "LocalRepo.h"
#import "LocalAccount.h"

#import "IssueIdentifier.h"

@implementation LocalIssue

- (void)willSave {
    NSNumber *closed = self.closed;
    NSNumber *newClosed = [[self state] isEqualToString:@"closed"] ? @YES : @NO;
    
    if (![closed isEqual:newClosed]) {
        self.closed = newClosed;
    }
    
    [super willSave];
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:@"pullRequest"]) {
        if ([value isKindOfClass:[NSDictionary class]]) {
            value = @YES;
        }
    }
    [super setValue:value forKey:key];
}

- (NSString *)fullIdentifier {
    if (!self.repository.fullName || !self.number) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@#%lld", self.repository.fullName, self.number.longLongValue];
}

@end
