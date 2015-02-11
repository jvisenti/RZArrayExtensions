//
//  NSArray+RZDataBinding.m
//
//  Created by Rob Visentin on 12/4/14.
//

// Copyright 2014 Raizlabs and other contributors
// http://raizlabs.com/
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

@import ObjectiveC.runtime;
@import ObjectiveC.message;

#import "NSObject+RZDataBinding.h"
#import "NSArray+RZDataBinding.h"

NSString* const kRZDBObjectUpdateKey = @"RZDBObjectUpdateKey";

typedef NS_ENUM(NSUInteger, RZDBArrayMutationType) {
    kRZDBArrayMutationTypeUnknown   = 0,
    kRZDBArrayMutationTypeRemove,
    kRZDBArrayMutationTypeInsert,
    kRZDBArrayMutationTypeMove,
    kRZDBArrayMutationTypeUpdate
};

static NSString* const kRZDBIgnoredClassCharacters = @"NS_";
static NSString* const kRZDBDynamicClassPrefix = @"__RZDB";

static void* const kRZDBBatchUpdateNumKey = (void *)&kRZDBBatchUpdateNumKey;

// prototype to silence warnings
struct objc_super _rz_super(id obj);
struct objc_super _rz_super(id obj)
{
    return (struct objc_super){
        obj,
        [obj superclass]
    };
}

// prototype to silence warnings
Class _rz_class_copyTemplate(Class template, Class newSuperclass, const char *newName);
Class _rz_class_copyTemplate(Class template, Class newSuperclass, const char *newName)
{
    // NOTE: assuming templates don't have ivars or properties (since they wouldn't be allocated for existing instances)
    
    Class newClass = objc_allocateClassPair(newSuperclass, newName, 0);
    
    unsigned int numMethods;
    Method *methods = class_copyMethodList(template, &numMethods);
    
    for ( unsigned int m = 0; m < numMethods; m++ ) {
        Method method = methods[m];
        
        class_addMethod(newClass, method_getName(method), method_getImplementation(method), method_getTypeEncoding(method));
    }
    
    free(methods);
    
    objc_registerClassPair(newClass);
    
    return newClass;
}

#pragma mark - RZDBArrayMutation interface

@interface RZDBArrayMutation : NSObject

@property (assign, nonatomic) RZDBArrayMutationType mutationType;
@property (strong, nonatomic) NSArray *objects;
@property (copy, nonatomic) NSIndexSet *indexes;

+ (instancetype)removeMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes;
+ (instancetype)insertMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes;
+ (instancetype)moveMutationWithIndexes:(NSIndexSet *)indexes;
+ (instancetype)updateMutationWithIndexes:(NSIndexSet *)indexes;

@end

#pragma mark - RZDBMutableArrayTemplate interface

@interface RZDBMutableArrayTemplate : NSMutableArray

- (void)_rz_removeObjectsInRangeSilently:(NSRange)range;

@end

#pragma mark - RZDBArrayProxy interface

@interface RZDBArrayProxy : NSProxy

@property (strong, nonatomic) NSMutableArray *backingArray;

@end

#pragma mark - RZDataBinding_Private interface

@interface NSArray (RZDataBinding_Private)

- (NSPointerArray *)_rz_arrayObservers;

#pragma mark - observer notification

- (void)_rz_objectUpdated:(NSDictionary *)change;

- (void)_rz_notifyObserversOfBatchUpdate:(BOOL)batchUpdating;

- (void)_rz_notifyObserversOfMutation:(RZDBArrayMutation *)mutation prior:(BOOL)prior;
- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofRemove:(RZDBArrayMutation *)remove prior:(BOOL)prior;
- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofInsert:(RZDBArrayMutation *)insert prior:(BOOL)prior;
- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofMove:(RZDBArrayMutation *)move prior:(BOOL)prior;
- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofUpdate:(RZDBArrayMutation *)update;

#pragma mark - batch updating

- (BOOL)_rz_isBatchUpdating;
- (void)_rz_pushBatchUpdate;
- (void)_rz_popBatchUpdateForce:(BOOL)force;

- (NSMutableDictionary *)_rz_pendingNotifications;
- (void)_rz_setPendingNotifications:(NSMutableDictionary *)pendingNotifications;

- (NSArray *)_rz_preBatchObjects;
- (void)_rz_setPreBatchObjects:(NSArray *)preBatchObjects;

- (void)_rz_addBatchUpdate:(RZDBArrayMutation *)update;
- (void)_rz_sendPendingNotifications;

@end

#pragma mark - RZDataBinding implementation

@implementation NSArray (RZDataBinding)

- (void)rz_addObserver:(id<RZDBArrayObserver>)observer
{
    NSParameterAssert(observer);
    
    NSPointerArray *observers = [self _rz_arrayObservers];
    [observers compact];
    
    NSUInteger obsIdx = [[observers allObjects] indexOfObjectIdenticalTo:observer];
    
    if ( obsIdx == NSNotFound ) {
        if ( [observers count] == 0 ) {
            [self enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                [obj rz_addTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
            }];
        }

        [observers addPointer:(__bridge void *)(observer)];
    }
}

- (void)rz_removeObserver:(id<RZDBArrayObserver>)observer
{
    NSPointerArray *observers = [self _rz_arrayObservers];
    [observers compact];
    
    NSUInteger obsIdx = [[observers allObjects] indexOfObjectIdenticalTo:observer];
    
    if ( obsIdx != NSNotFound ) {
        if ( [observers count] == 1 ) {
            [self enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                [obj rz_removeTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
            }];
        }

        [observers removePointerAtIndex:obsIdx];
    }
}

- (void)rz_sendUpdateNotificationForObject:(id)object
{
    NSUInteger idx = [self indexOfObjectIdenticalTo:object];

    if ( idx != NSNotFound ) {
        RZDBArrayMutation *update = [RZDBArrayMutation updateMutationWithIndexes:[NSIndexSet indexSetWithIndex:idx]];

        if ( [self _rz_isBatchUpdating] ) {
            [self _rz_addBatchUpdate:update];
        }
        else {
            [self _rz_notifyObserversOfMutation:update prior:NO];
        }
    }
}

- (void)rz_beginBatchUpdates
{
    if ( ![self _rz_isBatchUpdating] ) {
        NSMutableDictionary *pendingNotifications = [NSMutableDictionary dictionary];
        
        pendingNotifications[@(kRZDBArrayMutationTypeInsert)] = [NSMutableIndexSet indexSet];
        pendingNotifications[@(kRZDBArrayMutationTypeUpdate)] = [NSMutableIndexSet indexSet];
        pendingNotifications[@(kRZDBArrayMutationTypeMove)] = [NSMutableIndexSet indexSet];
        pendingNotifications[@(kRZDBArrayMutationTypeRemove)] = [NSMutableIndexSet indexSet];
        
        [self _rz_setPreBatchObjects:self];
        [self _rz_setPendingNotifications:pendingNotifications];
        
        [self _rz_notifyObserversOfBatchUpdate:YES];
    }
    
    [self _rz_pushBatchUpdate];
}

- (void)rz_endBatchUpdates:(BOOL)force
{
    if ( [self _rz_isBatchUpdating] ) {
        [self _rz_popBatchUpdateForce:force];
        
        if ( ![self _rz_isBatchUpdating] ) {
            [self _rz_sendPendingNotifications];
            
            [self _rz_setPreBatchObjects:nil];
            [self _rz_setPendingNotifications:nil];
            
            [self _rz_notifyObserversOfBatchUpdate:NO];
        }
    }
}

@end

@implementation NSMutableArray (RZDataBinding)

- (void)rz_addObserver:(id<RZDBArrayObserver>)observer
{
    [super rz_addObserver:observer];
    
    NSString *newClassName = NSStringFromClass([self class]);
    newClassName = [newClassName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:kRZDBIgnoredClassCharacters]];
    newClassName = [kRZDBDynamicClassPrefix stringByAppendingString:newClassName];
    
    Class newClass = NSClassFromString(newClassName);
    
    if ( newClass == nil ) {
        newClass = _rz_class_copyTemplate([RZDBMutableArrayTemplate class], [self class], [newClassName UTF8String]);
    }
    
    object_setClass(self, newClass);
}

- (NSArray *)rz_immutableProxy
{
    RZDBArrayProxy *proxy = [RZDBArrayProxy alloc];
    proxy.backingArray = self;
    
    return (NSArray *)proxy;
}

@end

#pragma mark - RZDataBinding_Private implementation

@implementation NSArray (RZDataBinding_Private)

- (NSPointerArray *)_rz_arrayObservers
{
    NSPointerArray *observers = objc_getAssociatedObject(self, _cmd);
    
    if ( observers == nil ) {
        observers = [NSPointerArray pointerArrayWithOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)];
        objc_setAssociatedObject(self, _cmd, observers, OBJC_ASSOCIATION_RETAIN);
    }
    
    return observers;
}

#pragma mark - observer notification

- (void)_rz_objectUpdated:(NSDictionary *)change
{
    id object = change[kRZDBChangeKeyObject];

    if ( [self _rz_isBatchUpdating] ) {
        [self rz_sendUpdateNotificationForObject:object];
    }
    else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rz_sendUpdateNotificationForObject:) object:object];
        [self performSelector:@selector(rz_sendUpdateNotificationForObject:) withObject:object afterDelay:0.0];
    }
}

- (void)_rz_notifyObserversOfBatchUpdate:(BOOL)batchUpdating
{
    NSPointerArray *observers = [self _rz_arrayObservers];
    
    [observers compact];
    [[observers allObjects] enumerateObjectsUsingBlock:^(id<RZDBArrayObserver> obs, NSUInteger idx, BOOL *stop) {
        if ( batchUpdating && [obs respondsToSelector:@selector(arrayWillBeginBatchUpdates:)] ) {
            [obs arrayWillBeginBatchUpdates:self];
        }
        else if ( !batchUpdating && [obs respondsToSelector:@selector(arrayDidEndBatchUpdates:)] ) {
            [obs arrayDidEndBatchUpdates:self];
        }
    }];
}

- (void)_rz_notifyObserversOfMutation:(RZDBArrayMutation *)mutation prior:(BOOL)prior
{
    NSPointerArray *observers = [self _rz_arrayObservers];
    [observers compact];
    
    if ( observers.count > 0 ) {
        BOOL batchUpdating = [self _rz_isBatchUpdating];
        
        if ( prior && batchUpdating ) {
            [self _rz_addBatchUpdate:mutation];
        }
        
        if ( prior || !batchUpdating ) {
            [[observers allObjects] enumerateObjectsUsingBlock:^(id<RZDBArrayObserver> observer, NSUInteger idx, BOOL *stop) {
                switch ( mutation.mutationType ) {
                    case kRZDBArrayMutationTypeRemove: {
                        [self _rz_notifyObserver:observer ofRemove:mutation prior:prior];
                        break;
                    }

                    case kRZDBArrayMutationTypeInsert: {
                        [self _rz_notifyObserver:observer ofInsert:mutation prior:prior];
                        break;
                    }

                    case kRZDBArrayMutationTypeMove: {
                        [self _rz_notifyObserver:observer ofMove:mutation prior:prior];
                        break;
                    }

                    case kRZDBArrayMutationTypeUpdate: {
                        [self _rz_notifyObserver:observer ofUpdate:mutation];
                        break;
                    }

                    default:
                        break;
                }
            }];
        }
    }
}

- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofRemove:(RZDBArrayMutation *)remove prior:(BOOL)prior
{
    if ( prior && [observer respondsToSelector:@selector(array:willRemoveObjectsAtIndexes:)] ) {
        [observer array:self willRemoveObjectsAtIndexes:remove.indexes];
    }
    else if ( !prior && [observer respondsToSelector:@selector(array:didRemoveObjects:atIndexes:)] ) {
        [observer array:self didRemoveObjects:remove.objects atIndexes:remove.indexes];
    }
}

- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofInsert:(RZDBArrayMutation *)insert prior:(BOOL)prior
{
    if ( prior && [observer respondsToSelector:@selector(array:willInsertObjects:atIndexes:)] ) {
        [observer array:self willInsertObjects:insert.objects atIndexes:insert.indexes];
    }
    else if ( !prior && [observer respondsToSelector:@selector(array:didInsertObjectsAtIndexes:)] ) {
        [observer array:self didInsertObjectsAtIndexes:insert.indexes];
    }
}

- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofMove:(RZDBArrayMutation *)move prior:(BOOL)prior
{
    // NOTE: moves are always part of a batch operation
    [move.indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSUInteger oldIndex = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:self[idx]];

        if ( prior && [observer respondsToSelector:@selector(array:willMoveObjectAtIndex:toIndex:)] ) {
            [observer array:self willMoveObjectAtIndex:oldIndex toIndex:idx];
        }
        else if ( !prior && [observer respondsToSelector:@selector(array:didMoveObjectAtIndex:toIndex:)] ) {
            [observer array:self didMoveObjectAtIndex:oldIndex toIndex:idx];
        }
    }];
}

- (void)_rz_notifyObserver:(id<RZDBArrayObserver>)observer ofUpdate:(RZDBArrayMutation *)update
{
    if ( ![self _rz_isBatchUpdating] && [observer respondsToSelector:@selector(array:didUpdateObjectsAtIndexes:)] ) {
        [observer array:self didUpdateObjectsAtIndexes:update.indexes];
    }
}

#pragma mark - batch updating

- (BOOL)_rz_isBatchUpdating
{
    return ([objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue] > 0);
}

- (void)_rz_pushBatchUpdate
{
    NSUInteger count = [objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue];
    objc_setAssociatedObject(self, kRZDBBatchUpdateNumKey, @(++count), OBJC_ASSOCIATION_RETAIN);
}

- (void)_rz_popBatchUpdateForce:(BOOL)force
{
    NSUInteger count = [objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue];

    if ( count > 0 ) {
        count = force ? 0 : (count - 1);
        objc_setAssociatedObject(self, kRZDBBatchUpdateNumKey, @(count), OBJC_ASSOCIATION_RETAIN);
    }
}

- (void)_rz_setBatchUpdating:(BOOL)updating force:(BOOL)force
{
    NSUInteger state = [objc_getAssociatedObject(self, _cmd) unsignedIntegerValue];

    if ( updating ) {
        state = force ? 0 : (state + 1);
    }
    else if ( !updating && state > 0 ) {
        state--;
    }

    objc_setAssociatedObject(self, @selector(_rz_isBatchUpdating), @(state), OBJC_ASSOCIATION_RETAIN);
}

- (NSMutableArray *)_rz_pendingNotifications
{
    return objc_getAssociatedObject(self, _cmd);
}

- (void)_rz_setPendingNotifications:(NSMutableDictionary *)pendingNotifications
{
    objc_setAssociatedObject(self, @selector(_rz_pendingNotifications), pendingNotifications, OBJC_ASSOCIATION_RETAIN);
}

- (NSArray *)_rz_preBatchObjects
{
    return objc_getAssociatedObject(self, _cmd);
}

- (void)_rz_setPreBatchObjects:(NSArray *)preBatchObjects
{
    objc_setAssociatedObject(self, @selector(_rz_preBatchObjects), preBatchObjects, OBJC_ASSOCIATION_COPY);
}

- (void)_rz_addBatchUpdate:(RZDBArrayMutation *)update
{
    NSMutableDictionary *pendingNotifications = [self _rz_pendingNotifications];

    NSMutableIndexSet *inserts = pendingNotifications[@(kRZDBArrayMutationTypeInsert)];
    NSMutableIndexSet *updates = pendingNotifications[@(kRZDBArrayMutationTypeUpdate)];
    NSMutableIndexSet *moves = pendingNotifications[@(kRZDBArrayMutationTypeMove)];
    NSMutableIndexSet *removes = pendingNotifications[@(kRZDBArrayMutationTypeRemove)];

    [update.indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        switch ( update.mutationType ) {

            case kRZDBArrayMutationTypeRemove: {
                [updates shiftIndexesStartingAtIndex:idx + 1 by:-1];
                [inserts shiftIndexesStartingAtIndex:idx + 1 by:-1];
                [moves shiftIndexesStartingAtIndex:idx + 1 by:-1];

                // get index of removed object prior to updates
                NSUInteger remIdx = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:self[idx]];

                if ( remIdx != NSNotFound ) {
                    // adjust previous remove indexes accordingly
                    [removes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
                        if ( NSLocationInRange(remIdx, range) ) {
                            [removes shiftIndexesStartingAtIndex:range.location by:1];
                            [removes shiftIndexesStartingAtIndex:NSMaxRange(range) + 1 by:-1];
                            *stop = YES;
                        }
                    }];

                    [removes addIndex:remIdx];
                }
            }
                break;

            case kRZDBArrayMutationTypeInsert: {
                [updates shiftIndexesStartingAtIndex:idx by:1];
                [inserts shiftIndexesStartingAtIndex:idx by:1];
                [moves shiftIndexesStartingAtIndex:idx by:1];

                [inserts addIndex:idx];
            }
                break;

            case kRZDBArrayMutationTypeMove: {
                if ( [updates containsIndex:idx] ) {
                    NSUInteger oldIdx = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:self[idx]];

                    [updates removeIndex:idx];
                    [updates addIndex:oldIdx];
                }

                [moves addIndex:idx];
            }
                break;

            case kRZDBArrayMutationTypeUpdate: {
                [updates addIndex:idx];
            }
                break;

            default:
                break;
        }
    }];
}

- (void)_rz_sendPendingNotifications
{
    NSDictionary *updates = [[self _rz_pendingNotifications] copy];
    
    NSArray *notificationOrder = @[@(kRZDBArrayMutationTypeRemove), @(kRZDBArrayMutationTypeInsert), @(kRZDBArrayMutationTypeMove), @(kRZDBArrayMutationTypeUpdate)];
    
    [notificationOrder enumerateObjectsUsingBlock:^(NSNumber *key, NSUInteger idx, BOOL *stop) {
        NSIndexSet *pendingMutations = updates[key];
        
        if ( pendingMutations.count ) {
            RZDBArrayMutationType mutationType = [key unsignedIntegerValue];
            NSIndexSet *indexes = updates[key];

            RZDBArrayMutation *mutation = nil;

            switch ( mutationType ) {
                case kRZDBArrayMutationTypeRemove:
                    mutation = [RZDBArrayMutation removeMutationWithObjects:[[self _rz_preBatchObjects] objectsAtIndexes:indexes] indexes:indexes];
                    break;

                case kRZDBArrayMutationTypeInsert:
                    mutation = [RZDBArrayMutation insertMutationWithObjects:[self objectsAtIndexes:indexes] indexes:indexes];
                    break;

                case kRZDBArrayMutationTypeMove:
                    mutation = [RZDBArrayMutation moveMutationWithIndexes:indexes];
                    break;

                case kRZDBArrayMutationTypeUpdate:
                    mutation = [RZDBArrayMutation updateMutationWithIndexes:indexes];
                    break;
                    
                default:
                    break;
            }

            // all post-batch notifications are didChange
            [self _rz_notifyObserversOfMutation:mutation prior:NO];
        }
    }];
}

@end

#pragma mark - RZDBMutableArrayTemplate implementation

@implementation RZDBMutableArrayTemplate

- (void)_rz_removeObjectsInRangeSilently:(NSRange)range
{
    while ( range.length > 0 ) {
        [self[range.location] rz_removeTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];

        struct objc_super rzSuper = _rz_super(self);
        ((void (*)(struct objc_super*, SEL, NSUInteger))objc_msgSendSuper)(&rzSuper, @selector(removeObjectAtIndex:), range.location);
        
        range.length--;
    }
}

#pragma mark - category overrides

- (void)rz_addObserver:(id<RZDBArrayObserver>)observer
{
    // no need to go through NSMutableArray's class-changing implementation
    struct objc_super arraySuper = {
        self,
        [NSArray class]
    };
    
    ((void (*)(struct objc_super*, SEL, id))objc_msgSendSuper)(&arraySuper, _cmd, observer);
}

- (void)rz_removeObserver:(id<RZDBArrayObserver>)observer
{
    [super rz_removeObserver:observer];
    
    if ( [self _rz_arrayObservers].count == 0 ) {
        [self rz_endBatchUpdates:YES];
        
        object_setClass(self, [self superclass]);
    }
}

#pragma mark - remove overrides

- (void)removeObjectAtIndex:(NSUInteger)index
{
    [self removeObjectsAtIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)removeObjectsAtIndexes:(NSIndexSet *)indexes
{
    NSArray *objects = [self objectsAtIndexes:indexes];
    RZDBArrayMutation *mutation = [RZDBArrayMutation removeMutationWithObjects:objects indexes:indexes];

    [self _rz_notifyObserversOfMutation:mutation prior:YES];

    __block NSUInteger numRemoved = 0;

    [indexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        range.location -= numRemoved;
        [self _rz_removeObjectsInRangeSilently:range];
        numRemoved = range.length;
    }];

    [self _rz_notifyObserversOfMutation:mutation prior:NO];
}

- (void)removeObjectsInRange:(NSRange)range
{
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:range];
    NSArray *objects = [self objectsAtIndexes:indexes];
    RZDBArrayMutation *mutation = [RZDBArrayMutation removeMutationWithObjects:objects indexes:indexes];

    [self _rz_notifyObserversOfMutation:mutation prior:YES];

    [self _rz_removeObjectsInRangeSilently:range];

    [self _rz_notifyObserversOfMutation:mutation prior:NO];
}

- (void)removeAllObjects
{
    [self removeObjectsInRange:NSMakeRange(0, self.count)];
}

#pragma mark - insert overrides

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index
{
    [self insertObjects:@[anObject] atIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)insertObjects:(NSArray *)objects atIndexes:(NSIndexSet *)indexes
{
    RZDBArrayMutation *mutation = [RZDBArrayMutation insertMutationWithObjects:objects indexes:indexes];

    [self _rz_notifyObserversOfMutation:mutation prior:YES];

    __block NSUInteger curIndex = [indexes firstIndex];
    
    [objects enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        
        struct objc_super rzSuper = _rz_super(self);
        ((void (*)(struct objc_super*, SEL, id, NSUInteger))objc_msgSendSuper)(&rzSuper, @selector(insertObject:atIndex:), obj, curIndex);

         [obj rz_addTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
        
        curIndex = [indexes indexGreaterThanIndex:curIndex];
    }];
    
    [self _rz_notifyObserversOfMutation:mutation prior:NO];
}

#pragma mark - replace overrides

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
    [self replaceObjectsAtIndexes:[NSIndexSet indexSetWithIndex:index] withObjects:@[anObject]];
}

- (void)replaceObjectsAtIndexes:(NSIndexSet *)indexes withObjects:(NSArray *)objects
{
    [self rz_beginBatchUpdates];

    NSMutableIndexSet *replacingInserts = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *inserts = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *moves = [NSMutableIndexSet indexSet];
    
    __block NSUInteger curIndex = [indexes firstIndex];

    // TODO: what if this is called mid-batch update?
    
    [objects enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSUInteger objIdx = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:obj];
        
        if ( objIdx == NSNotFound ) {
            [inserts addIndex:curIndex];
            [replacingInserts addIndex:idx];
        }
        else if ( objIdx != curIndex ) {
            [moves addIndex:curIndex];
        }
        
        curIndex = [indexes indexGreaterThanIndex:curIndex];
    }];

    RZDBArrayMutation *removeMutation = nil;
    RZDBArrayMutation *insertMutation = nil;
    RZDBArrayMutation *moveMutation = nil;
    
    if ( inserts.count > 0 ) {
        removeMutation = [RZDBArrayMutation removeMutationWithObjects:[self objectsAtIndexes:inserts] indexes:inserts];

        insertMutation = [RZDBArrayMutation insertMutationWithObjects:[objects objectsAtIndexes:replacingInserts] indexes:inserts];

        [self _rz_notifyObserversOfMutation:removeMutation prior:YES];
        [self _rz_notifyObserversOfMutation:insertMutation prior:YES];
    }
    
    if ( moves.count > 0 ) {
        moveMutation = [RZDBArrayMutation moveMutationWithIndexes:moves];

        [self _rz_notifyObserversOfMutation:moveMutation prior:YES];
    }

    curIndex = [indexes firstIndex];
    
    [objects enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {

        if ( [inserts containsIndex:idx] ) {
            [self[curIndex] rz_removeTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
        }

        struct objc_super rzSuper = _rz_super(self);
        ((void (*)(struct objc_super*, SEL, NSUInteger, id))objc_msgSendSuper)(&rzSuper, @selector(replaceObjectAtIndex:withObject:), curIndex, obj);

        if ( [inserts containsIndex:idx] ) {
            [obj rz_addTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
        }

        curIndex = [indexes indexGreaterThanIndex:curIndex];
    }];

    if ( insertMutation != nil ) {
        [self _rz_notifyObserversOfMutation:removeMutation prior:NO];
        [self _rz_notifyObserversOfMutation:insertMutation prior:NO];
    }
    
    if ( moveMutation != nil ) {
        [self _rz_notifyObserversOfMutation:moveMutation prior:NO];
    }
    
    [self rz_endBatchUpdates:NO];
}

#pragma mark - exchange overrides

- (void)exchangeObjectAtIndex:(NSUInteger)idx1 withObjectAtIndex:(NSUInteger)idx2
{
    if ( idx1 == idx2 ) {
        return;
    }
    
    [self rz_beginBatchUpdates];

    RZDBArrayMutation *firstMove = [RZDBArrayMutation moveMutationWithIndexes:[NSIndexSet indexSetWithIndex:idx1]];
    RZDBArrayMutation *secondMove = [RZDBArrayMutation moveMutationWithIndexes:[NSIndexSet indexSetWithIndex:idx2]];
    
    [self _rz_notifyObserversOfMutation:firstMove prior:YES];
    [self _rz_notifyObserversOfMutation:secondMove prior:YES];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSUInteger, NSUInteger))objc_msgSendSuper)(&rzSuper, _cmd, idx1, idx2);

    [self _rz_notifyObserversOfMutation:firstMove prior:NO];
    [self _rz_notifyObserversOfMutation:secondMove prior:NO];
    
    [self rz_endBatchUpdates:NO];
}

#pragma mark - sort overrides

- (void)sortUsingComparator:(NSComparator)cmptr
{
    [self rz_beginBatchUpdates];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSComparator))objc_msgSendSuper)(&rzSuper, _cmd, cmptr);
    
    [self rz_endBatchUpdates:NO];
}

- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator)cmptr
{
    [self rz_beginBatchUpdates];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSSortOptions, NSComparator))objc_msgSendSuper)(&rzSuper, _cmd, opts, cmptr);
    
    [self rz_endBatchUpdates:NO];
}

- (void)sortUsingSelector:(SEL)comparator
{
    [self rz_beginBatchUpdates];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, SEL))objc_msgSendSuper)(&rzSuper, _cmd, comparator);
    
    [self rz_endBatchUpdates:NO];
}

- (void)sortUsingDescriptors:(NSArray *)sortDescriptors
{
    [self rz_beginBatchUpdates];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSArray*))objc_msgSendSuper)(&rzSuper, _cmd, sortDescriptors);
    
    [self rz_endBatchUpdates:NO];
}

- (void)sortUsingFunction:(NSInteger (*)(__strong id, __strong id, void *))compare context:(void *)context
{
    [self rz_beginBatchUpdates];
    
    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSInteger (*)(__strong id, __strong id, void *), void*))objc_msgSendSuper)(&rzSuper, _cmd, compare, context);
    
    [self rz_endBatchUpdates:NO];
}

@end

#pragma mark - RZDBArrayProxy implementation

@implementation RZDBArrayProxy

+ (Class)class
{
    return [NSArray class];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    NSMethodSignature *methodSig = nil;
    
    if ( [NSArray instancesRespondToSelector:sel] ) {
        methodSig = [self.backingArray methodSignatureForSelector:sel];
    }
    
    return methodSig;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    if ( [NSStringFromSelector(invocation.selector) hasPrefix:@"enumerateObjects"] ) {
        [invocation invokeWithTarget:[self.backingArray copy]];
    }
    else {
        [invocation invokeWithTarget:self.backingArray];
    }
}

- (void)doesNotRecognizeSelector:(SEL)aSelector
{
    [NSException raise:NSInvalidArgumentException format:@"-[%@ %@]: unrecognized selector sent to instance %p", [self class], NSStringFromSelector(aSelector), self];
}

#pragma mark - NSObject Protocol

- (Class)class
{
    return [NSArray class];
}

- (NSUInteger)hash
{
    return self.backingArray.hash;
}

- (BOOL)isEqual:(id)object
{
    BOOL equal = (object == self) || (object == self.backingArray);
    
    if ( !equal ) {
        equal = [self.backingArray isEqual:object];
    }
    
    return equal;
}

- (NSString *)description
{
    return [[self.backingArray copy] description];
}

- (NSString *)debugDescription
{
    return [[self.backingArray copy] debugDescription];
}

@end

@interface NSObject (RZDBObjectUpdates)
@end

@implementation NSObject (RZDBObjectUpdates)

- (id)RZDBObjectUpdateKey
{
    return nil;
}

- (void)setRZDBObjectUpdateKey {}

@end

#pragma mark - RZDBArrayMutation implementation

@implementation RZDBArrayMutation

#pragma mark - public methods

+ (instancetype)removeMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes
{
    return [self mutationWithType:kRZDBArrayMutationTypeRemove objects:objects indexes:indexes];
}

+ (instancetype)insertMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes
{
    return [self mutationWithType:kRZDBArrayMutationTypeInsert objects:objects indexes:indexes];
}

+ (instancetype)moveMutationWithIndexes:(NSIndexSet *)indexes
{
    return [self mutationWithType:kRZDBArrayMutationTypeMove objects:nil indexes:indexes];
}

+ (instancetype)updateMutationWithIndexes:(NSIndexSet *)indexes
{
    return [self mutationWithType:kRZDBArrayMutationTypeUpdate objects:nil indexes:indexes];
}

#pragma mark - private methods

+ (instancetype)mutationWithType:(RZDBArrayMutationType)type objects:(NSArray *)objects indexes:(NSIndexSet *)indexes
{
    RZDBArrayMutation *mutation = [[self alloc] init];
    mutation.mutationType = type;
    mutation.objects = objects;
    mutation.indexes = indexes;

    return mutation;
}

@end
