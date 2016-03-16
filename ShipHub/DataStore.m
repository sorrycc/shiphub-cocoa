//
//  DataStore.m
//  ShipHub
//
//  Created by James Howard on 3/8/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import "DataStore.h"

#import "Auth.h"
#import "Extras.h"
#import "Reachability.h"
#import "ServerConnection.h"
#import "SyncConnection.h"

#import "LocalAccount.h"
#import "LocalUser.h"
#import "LocalOrg.h"
#import "LocalRepo.h"
#import "LocalLabel.h"
#import "LocalMilestone.h"
#import "LocalIssue.h"
#import "LocalEvent.h"
#import "LocalComment.h"
#import "LocalRelationship.h"

NSString *const DataStoreWillBeginMigrationNotification = @"DataStoreWillBeginMigrationNotification";
NSString *const DataStoreDidEndMigrationNotification = @"DataStoreDidEndMigrationNotification";
NSString *const DataStoreMigrationProgressKey = @"DataStoreMigrationProgressKey";

NSString *const DataStoreActiveDidChangeNotification = @"DataStoreActiveDidChangeNotification";

NSString *const DataStoreDidUpdateMetadataNotification = @"DataStoreDidUpdateMetadataNotification";
NSString *const DataStoreMetadataKey = @"DataStoreMetadataKey";

NSString *const DataStoreDidUpdateProblemsNotification = @"DataStoreDidUpdateProblemsNotification";
NSString *const DataStoreUpdatedProblemsKey = @"DataStoreUpdatedProblemsKey";
NSString *const DataStoreUpdateProblemSourceKey = @"DataStoreUpdateProblemSourceKey";

NSString *const DataStoreDidUpdateOutboxNotification = @"DataStoreDidUpdateOutboxNotification";
NSString *const DataStoreOutboxResolvedProblemIdentifiersKey = @"DataStoreOutboxResolvedProblemIdentifiersKey";

NSString *const DataStoreDidPurgeNotification = @"DataStoreDidPurgeNotification";
NSString *const DataStoreWillPurgeNotification = @"DataStoreWillPurgeNotification";

NSString *const DataStoreDidUpdateMyQueriesNotification = @"DataStoreDidUpdateQueriesNotification";

NSString *const DataStoreCannotOpenDatabaseNotification = @"DataStoreCannotOpenDatabaseNotification";

NSString *const DataStoreWillBeginInitialMetadataSync = @"DataStoreWillBeginInitialMetadataSync";
NSString *const DataStoreDidEndInitialMetadataSync = @"DataStoreDidEndInitialMetadataSync";

NSString *const DataStoreWillBeginNetworkActivityNotification = @"DataStoreWillBeginNetworkActivityNotification";
NSString *const DataStoreDidEndNetworkActivityNotification = @"DataStoreDidEndNetworkActivityNotification";
NSString *const DataStoreDidUpdateProgressNotification = @"DataStoreDidUpdateProgressNotification";

NSString *const DataStoreNeedsMandatorySoftwareUpdateNotification = @"DataStoreNeedsMandatorySoftwareUpdateNotification";

/*
 Change History:
 1: First Version
 */
static const NSInteger CurrentLocalModelVersion = 1;

@interface DataStore () <SyncConnectionDelegate> {
    NSManagedObjectModel *_mom;
    NSPersistentStore *_persistentStore;
    NSPersistentStoreCoordinator *_persistentCoordinator;
    NSManagedObjectContext *_moc;
    NSLock *_metadataLock;
    
    dispatch_queue_t _needsMetadataQueue;
    NSMutableArray *_needsMetadataItems;
    
    dispatch_queue_t _queryUploadQueue;
    NSMutableSet *_queryUploadProcessing; // only manipulated within _moc.
    NSMutableArray *_needsQuerySyncItems;
    dispatch_queue_t _needsQuerySyncQueue;

    NSString *_purgeVersion;
    
    NSMutableDictionary *_localMetadataCache; // only manipulated within _moc.
    
    NSInteger _initialSyncProgress;
    
    BOOL _sentNetworkActivityBegan;
    double _problemSyncProgress;
}

@property (strong) Auth *auth;
@property (strong) ServerConnection *serverConnection;
@property (strong) SyncConnection *syncConnection;

@property (readwrite, strong) NSDate *lastUpdated;

@end

@implementation DataStore

static DataStore *sActiveStore = nil;

+ (DataStore *)activeStore {
    DataStore *threadLocalStore = [[NSThread currentThread] threadDictionary][@"ActiveDataStore"];
    if (threadLocalStore) {
        return threadLocalStore;
    }
    return sActiveStore;
}

- (void)activate {
    sActiveStore = self;
    [[Defaults defaults] setObject:_auth.account.login forKey:DefaultsLastUsedAccountKey];
    [[Defaults defaults] synchronize];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DataStoreActiveDidChangeNotification object:self];
}

- (void)activateThreadLocal {
    NSThread *thread = [NSThread currentThread];
    thread.threadDictionary[@"ActiveDataStore"] = self;
}

- (void)deactivateThreadLocal {
    NSThread *thread = [NSThread currentThread];
    if (self == thread.threadDictionary[@"ActiveDataStore"]) {
        [thread.threadDictionary removeObjectForKey:@"ActiveDataStore"];
    }
}

- (void)deactivate {
    sActiveStore = nil;
}

- (BOOL)isActive {
    return sActiveStore == self;
}

+ (Class)serverConnectionClass {
    return [ServerConnection class];
}

+ (Class)syncConnectionClass {
    return [SyncConnection class];
}

+ (DataStore *)storeWithAuth:(Auth *)auth {
    return [[self alloc] initWithAuth:auth];
}

- (id)initWithAuth:(Auth *)auth {
    NSParameterAssert(auth);
    NSParameterAssert(auth.account.login);
    
    if (self = [super init]) {
        _auth = auth;
        
        _needsMetadataItems = [NSMutableArray array];
        _needsMetadataQueue = dispatch_queue_create("DataStore.ResolveMetadata", NULL);
        _metadataLock = [[NSLock alloc] init];
        _queryUploadQueue = dispatch_queue_create("DataStore.UploadQuery", NULL);
        _queryUploadProcessing = [NSMutableSet set];
        _needsQuerySyncItems = [NSMutableArray array];
        _needsQuerySyncQueue = dispatch_queue_create("DataStore.ResolveQueries", NULL);
        _localMetadataCache = [NSMutableDictionary dictionary];
        
        if (![self openDB]) {
            return nil;
        }
        
        self.serverConnection = [[[[self class] serverConnectionClass] alloc] initWithAuth:_auth];
        self.syncConnection = [[[[self class] syncConnectionClass] alloc] initWithAuth:_auth];
        self.syncConnection.delegate = self;
        
        [self loadMetadata];
        [self updateSyncConnectionWithVersions];
    }
    return self;
}

- (BOOL)isOffline {
    return ![[Reachability sharedInstance] isReachable];
}

- (BOOL)isValid {
    return _auth.authState == AuthStateValid && ![self isMigrating];
}

- (NSString *)_dbPath {
    NSAssert(_auth.account.shipIdentifier, @"Must have a user identifier to open the database");
    
    NSString *dbname = [NSString stringWithFormat:@"%@.db", ServerEnvironmentToString(DefaultsServerEnvironment())];
    
    NSString *basePath = [[[Defaults defaults] stringForKey:DefaultsLocalStoragePathKey] stringByExpandingTildeInPath];
    NSString *path = [basePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@", _auth.account.shipIdentifier, dbname]];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    return path;
}

- (BOOL)openDB {
    return [self openDBForceRecreate:NO];
}

static NSString *const StoreVersion = @"DataStoreVersion";
static NSString *const PurgeVersion = @"PurgeVersion";
static NSString *const LastUpdated = @"LastUpdated";

- (BOOL)openDBForceRecreate:(BOOL)forceRecreate {
    NSString *filename = [self _dbPath];
    
    DebugLog(@"Opening DB at path: %@", filename);
    
    NSURL *momURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"LocalModel" withExtension:@"momd"];
    _mom = [[NSManagedObjectModel alloc] initWithContentsOfURL:momURL];
    NSAssert(_mom, @"Must load mom from %@", momURL);
    
    _persistentCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_mom];
    NSAssert(_persistentCoordinator, @"Must load coordinator");
    NSURL *storeURL = [NSURL fileURLWithPath:filename];
    NSError *err = nil;
    
    NSDictionary *options = @{ NSMigratePersistentStoresAutomaticallyOption: @YES, NSInferMappingModelAutomaticallyOption: @YES };
    
    // Determine if a migration is needed
    NSDictionary *sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType URL:storeURL options:options error:&err];
    if (!_purgeVersion) {
        _purgeVersion = sourceMetadata[PurgeVersion];
    }
    NSInteger previousStoreVersion = sourceMetadata ? [sourceMetadata[StoreVersion] integerValue] : CurrentLocalModelVersion;
    
    if (previousStoreVersion > CurrentLocalModelVersion) {
        ErrLog(@"Database has version %td, which is newer than client version %td.", previousStoreVersion, CurrentLocalModelVersion);
        [[NSNotificationCenter defaultCenter] postNotificationName:DataStoreCannotOpenDatabaseNotification object:nil /*nil because we're about to fail to init*/ userInfo:nil];
        return NO;
    }
    
    if (forceRecreate) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[storeURL path]]) {
            [[NSFileManager defaultManager] removeItemAtURL:storeURL error:&err];
            if (err) {
                ErrLog(@"Error deleting obsolete db: %@", err);
            }
        }
        previousStoreVersion = CurrentLocalModelVersion;
    }
    
    NSPersistentStore *store = _persistentStore = [_persistentCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:@"Default" URL:storeURL options:options error:&err];
    if (!store) {
        ErrLog(@"Error adding persistent store: %@", err);
        if (!forceRecreate) {
            ErrLog(@"Will force database recreation");
            return [self openDBForceRecreate:YES];
        } else {
            return NO;
        }
    }
    
    NSMutableDictionary *storeMetadata = [sourceMetadata mutableCopy] ?: [NSMutableDictionary dictionary];
    storeMetadata[StoreVersion] = @(CurrentLocalModelVersion);
    if (_purgeVersion) {
        storeMetadata[PurgeVersion] = _purgeVersion;
    }
    [_persistentCoordinator setMetadata:storeMetadata forPersistentStore:store];
    
    _lastUpdated = storeMetadata[LastUpdated];
    
    _moc = [[SerializedManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    _moc.persistentStoreCoordinator = _persistentCoordinator;
    _moc.undoManager = nil; // don't care about undo-ing here, and it costs performance to have an undo manager.
    
    BOOL needsSnapshotRebuild = NO;
    BOOL needsKeywordUsageRebuild = NO;
    BOOL needsABResync = NO;
    BOOL needsToWatchOwnQueries = NO;
    BOOL needsMetadataResync = NO;
    
    (void)needsToWatchOwnQueries;
    
    if (needsSnapshotRebuild || needsKeywordUsageRebuild) {
        _migrating = YES;
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
        [[NSNotificationCenter defaultCenter] postNotificationName:DataStoreWillBeginMigrationNotification object:self userInfo:@{DataStoreMigrationProgressKey : progress }];
        [self migrationRebuildSnapshots:needsSnapshotRebuild rebuildKeywordUsage:needsKeywordUsageRebuild withProgress:progress completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                _migrating = NO;
                [[NSNotificationCenter defaultCenter] postNotificationName:DataStoreDidEndMigrationNotification object:self userInfo:@{DataStoreMigrationProgressKey : progress }];
            });
        }];
    }
    
    if (needsMetadataResync) {
        DebugLog(@"Forcing metadata resync");
        [_moc performBlockAndWait:^{
#if 0
            [self setLatestSequence:0 syncType:@"addressBook"];
            [self setLatestSequence:0 syncType:@"classifications"];
            [self setLatestSequence:0 syncType:@"components"];
            [self setLatestSequence:0 syncType:@"milestones"];
            [self setLatestSequence:0 syncType:@"priorities"];
            [self setLatestSequence:0 syncType:@"states"];
#endif
            [_moc save:NULL];
        }];
    } else if (needsABResync) {
        DebugLog(@"Forcing address book resync");
        [_moc performBlockAndWait:^{
#if 0
            [self setLatestSequence:0 syncType:@"addressBook"];
#endif
            [_moc save:NULL];
        }];
    }
    
    return YES;
}

- (void)migrationRebuildSnapshots:(BOOL)rebuildSnapshots
              rebuildKeywordUsage:(BOOL)rebuildKeywordUsage
                     withProgress:(NSProgress *)progress
                       completion:(dispatch_block_t)completion
{
    NSAssert(rebuildSnapshots || rebuildKeywordUsage, @"Should be rebuilding at least something here");
    
    [self loadMetadata];
    [_moc performBlock:^{
        [self activateThreadLocal];
        
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSError *err = nil;
        
#if 0
        NSArray *problemIdentifiers = nil;
        if (rebuildSnapshots) {
            // Fetch the distinct set of problemIdentifiers in the database
            NSFetchRequest *distinct = [NSFetchRequest fetchRequestWithEntityName:@"LocalLogEntry"];
            distinct.resultType = NSDictionaryResultType;
            distinct.returnsDistinctResults = YES;
            distinct.propertiesToFetch = @[@"problemIdentifier"];
            problemIdentifiers = [_moc executeFetchRequest:distinct error:&err];
            if (err) {
                ErrLog(@"Error fetching distinct problemIdentifiers: %@", err);
            }
        }
        
        progress.totalUnitCount = [problemIdentifiers count] + (rebuildKeywordUsage ? 1 : 0);
        
        if (rebuildSnapshots) {
            int64_t i = 0;
            for (NSDictionary *result in problemIdentifiers) {
                [self updateSnapshot:result[@"problemIdentifier"]];
                i++;
                progress.completedUnitCount = i;
            }
        }
        
        if (rebuildKeywordUsage) {
            [self rebuildKeywordUsage];
            progress.completedUnitCount += 1;
        }
#endif
        
        err = nil;
        [_moc save:&err];
        if (err) {
            ErrLog(@"Error saving updated snapshots: %@", err);
        }
        
        CFAbsoluteTime end = CFAbsoluteTimeGetCurrent();
        DebugLog(@"Completed migration (snapshots:%d keywords:%d) in %.3fs", rebuildSnapshots, rebuildKeywordUsage, (end-start));
        (void)start; (void)end;
        
        [self deactivateThreadLocal];
    } completion:completion];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadMetadata {
    // FIXME: Implement
}

- (void)updateSyncConnectionWithVersions {
    [_moc performBlock:^{
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"LocalSyncVersion"];
        fetch.resultType = NSDictionaryResultType;
        NSError *err = nil;
        NSArray *results = [_moc executeFetchRequest:fetch error:&err];
        if (err) {
            ErrLog("%@", err);
        }
        
        // Convert [ { "type" : "user", "version" : 1234 }, ... ] =>
        // { "user" : 1234, ... }
        NSMutableDictionary *all = [NSMutableDictionary dictionaryWithCapacity:results.count];
        for (NSDictionary *pair in results) {
            all[pair[@"type"]] = pair[@"version"];
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.syncConnection syncWithVersions:all];
        });
    }];
}

// Must be called on _moc.
// Does not call save:
- (void)setLatestSyncVersion:(int64_t)version syncType:(NSString *)syncType {
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"LocalSyncVersion"];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"type = %@", syncType];
    fetchRequest.fetchLimit = 1;
    
    NSError *err = nil;
    NSArray *results = [_moc executeFetchRequest:fetchRequest error:&err];
    if (err) {
        ErrLog(@"%@", err);
        return;
    }
    
    NSManagedObject *obj = [results firstObject];
    if (!obj) {
        obj = [NSEntityDescription insertNewObjectForEntityForName:@"LocalSyncVersion" inManagedObjectContext:_moc];
        [obj setValue:syncType forKey:@"type"];
    }
    [obj setValue:@(version) forKey:@"version"];

}

// Must be called on _moc.
// Does not call save:
- (NSArray *)createPlaceholderEntitiesWithName:(NSString *)entityName withIdentifiers:(NSArray *)identifiers {
    NSParameterAssert(entityName);
    NSParameterAssert(identifiers);
    
    NSError *error = nil;
    NSFetchRequest *existing = [NSFetchRequest fetchRequestWithEntityName:entityName];
    existing.resultType = NSDictionaryResultType;
    existing.propertiesToFetch = @[@"identifier"];
    NSArray *ids = [[_moc executeFetchRequest:existing error:&error] arrayByMappingObjects:^id(id obj) {
        return [obj objectForKey:@"identifier"];
    }];
    
    if (error) {
        ErrLog(@"entity: %@ error: %@", entityName, error);
        return nil;
    }
    
    NSMutableSet *toCreate = [NSMutableSet setWithArray:identifiers];
    [toCreate minusSet:[NSSet setWithArray:ids]];
    
    NSMutableArray *created = [NSMutableArray arrayWithCapacity:toCreate.count];
    for (id identifier in toCreate) {
        NSManagedObject *newEntity = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:_moc];
        [newEntity setValue:identifier forKey:@"identifier"];
        [created addObject:newEntity];
    }
    
    return created;
}

- (void)syncConnection:(SyncConnection *)sync receivedRootIdentifiers:(NSDictionary *)rootIdentifiers version:(int64_t)version {
    DebugLog(@"%@\nversion: %qd", rootIdentifiers, version);
    [_moc performBlock:^{
        NSError *error = nil;
        
        // delete users who no longer exist.
        NSFetchRequest *deleteUsers = [NSFetchRequest fetchRequestWithEntityName:@"LocalUser"];
        deleteUsers.predicate = [NSPredicate predicateWithFormat:@"!(identifier IN %@)", rootIdentifiers[@"users"]];
        [_moc batchDeleteEntitiesWithRequest:deleteUsers error:&error];
        
        if (error) ErrLog(@"%@", error);
        error = nil;
        
        [self createPlaceholderEntitiesWithName:@"LocalUser" withIdentifiers:rootIdentifiers[@"users"]];
        
        
        // delete orgs that no longer exist.
        NSFetchRequest *deleteOrgs = [NSFetchRequest fetchRequestWithEntityName:@"LocalOrg"];
        deleteOrgs.predicate = [NSPredicate predicateWithFormat:@"!(identifier IN %@)", rootIdentifiers[@"orgs"]];
        [_moc batchDeleteEntitiesWithRequest:deleteOrgs error:&error];
        
        if (error) ErrLog("%@", error);
        error = nil;
        
        [self createPlaceholderEntitiesWithName:@"LocalOrg" withIdentifiers:rootIdentifiers[@"orgs"]];
        
        [self setLatestSyncVersion:version syncType:@"root"];
        
        [_moc save:&error];
        
        if (error) ErrLog("%@", error);
    }];
}

// Must be called on _moc.
// Does not call save:
- (void)updateLabelsOn:(NSManagedObject *)owner fromDicts:(NSArray *)lDicts relationship:(NSRelationshipDescription *)relationship {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"LocalLabel"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"%K = %@", relationship.inverseRelationship.name, owner];
    NSError *error = nil;
    NSArray *existingLabels = [_moc executeFetchRequest:fetch error:&error];
    if (error) ErrLog("%@", error);
    
    NSDictionary *existingLookup = [NSDictionary lookupWithObjects:existingLabels keyPath:@"name"];
    NSDictionary *lDictLookup = [NSDictionary lookupWithObjects:lDicts keyPath:@"name"];
    
    NSMutableSet *allNames = [NSMutableSet setWithArray:[existingLookup allKeys]];
    [allNames addObjectsFromArray:[lDictLookup allKeys]];
    
    NSMutableArray *relatedLabels = [[NSMutableArray alloc] initWithCapacity:lDicts.count];
    
    for (NSString *name in allNames) {
        NSDictionary *d = lDictLookup[name];
        LocalLabel *ll = existingLookup[name];
        
        if (ll && d) {
            [ll mergeAttributesFromDictionary:d];
            [relatedLabels addObject:ll];
        } else if (ll && !d) {
            [_moc deleteObject:ll];
        } else if (!ll && d) {
            ll = [NSEntityDescription insertNewObjectForEntityForName:@"LocalLabel" inManagedObjectContext:_moc];
            [ll mergeAttributesFromDictionary:d];
            [relatedLabels addObject:ll];
        }
    }
    
    [owner setValue:[NSSet setWithArray:relatedLabels] forKey:@"labels"];
}

// Must be called on _moc.
// Does not call save:
- (void)updateRelationshipsOn:(NSManagedObject *)obj fromSyncDict:(NSDictionary *)syncDict {
    
    NSDictionary *relationships = obj.entity.relationshipsByName;
    
    for (NSString *key in [relationships allKeys]) {
        NSRelationshipDescription *rel = relationships[key];
        
        if ([key isEqualToString:@"labels"]) {
            // labels are ... *sigh* ... special
            [self updateLabelsOn:(LocalRepo *)obj fromDicts:syncDict[@"labels"] relationship:rel];
            continue;
        }
        
        if (rel.toMany) {
            // Anything that cascades is considered a "strong" relationship, which
            // implies the ability to delete and create referenced objects as needed.
            BOOL cascade = rel.deleteRule == NSCascadeDeleteRule;
            
            // to many relationships refer by identifiers
            NSArray *relatedIDs = syncDict[key];
            if (!relatedIDs) relatedIDs = @[];
            NSSet *relatedIDSet = [NSSet setWithArray:relatedIDs];
            
            if (cascade) {
                // delete anything that's no longer being referenced
                id<NSFastEnumeration> originalRelatedObjs = [obj valueForKey:key];
                
                for (NSManagedObject *relObj in originalRelatedObjs) {
                    id identifier = [relObj valueForKey:@"identifier"];
                    if (![relatedIDSet containsObject:identifier]) {
                        DebugLog(@"Will delete relationship %@ to %@ (%@)", rel, relObj, identifier);
                        [_moc deleteObject:relObj];
                    }
                }
            }
            
            // find everything in relatedIDs that already exists
            NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:rel.destinationEntity.name];
            fetch.predicate = [NSPredicate predicateWithFormat:@"identifier IN %@", relatedIDs];
            
            NSError *error = nil;
            NSArray *existing = [_moc executeFetchRequest:fetch error:&error];
            NSMutableArray *relatedObjs = [NSMutableArray arrayWithArray:existing];
            if (error) ErrLog(@"%@", error);
            
            if (cascade) {
                // if we're the owner of this relationship, we also want to create placeholders
                // for anything that didn't come back in existing
                NSMutableSet *toCreate = [relatedIDs mutableCopy];
                for (NSManagedObject *relObj in existing) {
                    [toCreate removeObject:[relObj valueForKey:@"identifier"]];
                }
                
                for (id identifier in toCreate) {
                    NSManagedObject *relObj = [NSEntityDescription insertNewObjectForEntityForName:rel.destinationEntity.name inManagedObjectContext:_moc];
                    [relObj setValue:identifier forKey:@"identifier"];
                    [relatedObjs addObject:relObj];
                }
            }
            
            DebugLog(@"Setting relationships %@ forKey:%@", relatedObjs, key);
            [obj setValue:[NSSet setWithArray:relatedObjs] forKey:key];
            
        } else /* rel.toOne */ {
            // to one relationships are always considered weak in our schema
            
            NSString *relatedID = syncDict[key];
            if (relatedID != nil) {
                NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:rel.entity.name];
                fetch.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", relatedID];
                fetch.fetchLimit = 1;
                
                NSError *error = nil;
                
                NSManagedObject *relObj = [[_moc executeFetchRequest:fetch error:&error] firstObject];
                if (relObj) {
                    [obj setValue:relObj forKey:key];
                } else {
                    DebugLog(@"Could not locate related object (%@) in relationship %@", relatedID, rel);
                    [obj setValue:nil forKey:key];
                }
            }
        }
    }
}

- (void)syncConnection:(SyncConnection *)sync receivedSyncObjects:(NSArray *)objs type:(NSString *)type version:(int64_t)version {
    DebugLog(@"%@: %@\nversion:%qd", type, objs, version);
    
    [_moc performBlock:^{
        NSError *error = nil;
        
        NSString *entityName = [NSString stringWithFormat:@"Local%@", [type PascalCase]];
        NSAssert(_mom.entitiesByName[entityName] != nil, @"Entity %@ must exist", entityName);
        
        // Fetch all of the managed objects that we are going to update.
        // They should all exist already, if only just as placeholders in some cases.
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entityName];
        fetch.predicate = [NSPredicate predicateWithFormat:@"identifier IN %@.identifier", objs];
        
        NSArray *mObjs = [_moc executeFetchRequest:fetch error:&error];
        
        if (error) ErrLog("%@", error);
        error = nil;
        
#if DEBUG
        if ([objs count] != [mObjs count]) {
            ErrLog(@"Provided %@ list included unknown identifiers. This is a server bug. Unknown items will be ignored.", type);
        }
#endif
        
        NSDictionary *lookup = [NSDictionary lookupWithObjects:objs keyPath:@"identifier"];
        for (NSManagedObject *mObj in mObjs) {
            NSDictionary *objDict = lookup[[mObj valueForKey:@"identifier"]];
            [mObj mergeAttributesFromDictionary:objDict];
            [self updateRelationshipsOn:mObj fromSyncDict:objDict];
        }
        
        [self setLatestSyncVersion:version syncType:type];
        
        [_moc save:&error];
        if (error) ErrLog("%@", error);
    }];
}

@end
