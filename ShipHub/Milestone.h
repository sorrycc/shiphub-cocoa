//
//  Milestone.h
//  ShipHub
//
//  Created by James Howard on 3/21/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "MetadataItem.h"

@interface Milestone : MetadataItem

@property (readonly) NSNumber *number;
@property (readonly) NSString *title;
@property (readonly) NSDate *closedAt;
@property (readonly) NSDate *dueOn;
@property (readonly) NSString *milestoneDescription;
@property (readonly) NSDate *updatedAt;
@property (readonly) NSDate *createdAt;
@property (readonly) NSString *state;
@property (readonly) NSString *repoFullName;
@property (readonly, getter=isHidden) BOOL hidden;
@property (readonly, getter=isClosed) BOOL closed;

@end
