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

#import <objc/runtime.h>
#import <objc/message.h>

#import "NSArray+RZDataBinding.h"
#import "RZDBMacros.h"

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

static struct objc_super _rz_super(id obj)
{
    return (struct objc_super){
        obj,
        [obj superclass]
    };
}

static Class _rz_class_copyTemplate(Class template, Class newSuperclass, const char *newName)
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

@property (strong, nonatomic) NSIndexPath *movePath;

+ (instancetype)removeMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes;
+ (instancetype)insertMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes;
+ (instancetype)moveMutationFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx;
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

#pragma mark - NSArray+RZDataBinding_Private interface

@interface NSArray (RZDataBinding_Private)

- (NSHashTable *)_rz_arrayObservers;

#pragma mark - automatic updates

- (void)_rz_observeObject:(id)object;
- (void)_rz_objectUpdated:(NSDictionary *)change;
- (void)_rz_unobserveObject:(id)object force:(BOOL)force;

#pragma mark - observer notification

- (void)_rz_notifyObserversOfBatchUpdate:(BOOL)batchUpdating;
- (void)_rz_willMutate:(RZDBArrayMutation *)mutation;
- (void)_rz_didMutate:(RZDBArrayMutation *)mutation;

#pragma mark - batch updating

- (BOOL)_rz_isBatchUpdating;
- (void)_rz_closeBatchUpdateForce:(BOOL)force;

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
    
    NSHashTable *observers = [self _rz_arrayObservers];

    if ( ![observers containsObject:observer] ) {
        if ( observers.count == 0 ) {
            [self enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                [self _rz_observeObject:obj];
            }];
        }

        [observers addObject:observer];
    }
}

- (void)rz_removeObserver:(id<RZDBArrayObserver>)observer
{
    NSHashTable *observers = [self _rz_arrayObservers];
    
    if ( [observers containsObject:observer] ) {
        if ( observers.count == 1 ) {
            [self enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                [self _rz_unobserveObject:obj force:YES];
            }];
        }

        [observers removeObject:observer];
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
            [self _rz_didMutate:update];
        }
    }
}

- (void)rz_openBatchUpdate
{
    if ( ![self _rz_isBatchUpdating] ) {
        NSMutableDictionary *pendingNotifications = [NSMutableDictionary dictionary];
        
        pendingNotifications[@(kRZDBArrayMutationTypeInsert)] = [NSMutableIndexSet indexSet];
        pendingNotifications[@(kRZDBArrayMutationTypeUpdate)] = [NSMutableIndexSet indexSet];
        pendingNotifications[@(kRZDBArrayMutationTypeRemove)] = [NSMutableIndexSet indexSet];
        
        [self _rz_setPreBatchObjects:self];
        [self _rz_setPendingNotifications:pendingNotifications];
        
        [self _rz_notifyObserversOfBatchUpdate:YES];
    }

    NSUInteger count = [objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue];
    objc_setAssociatedObject(self, kRZDBBatchUpdateNumKey, @(++count), OBJC_ASSOCIATION_RETAIN);
}

- (void)rz_closeBatchUpdate
{
    if ( [self _rz_isBatchUpdating] ) {
        [self _rz_closeBatchUpdateForce:NO];
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

#pragma mark - NSArray+RZDataBinding_Private implementation

@implementation NSArray (RZDataBinding_Private)

- (NSHashTable *)_rz_arrayObservers
{
    NSHashTable *observers = objc_getAssociatedObject(self, _cmd);
    
    if ( observers == nil ) {
        observers = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(self, _cmd, observers, OBJC_ASSOCIATION_RETAIN);
    }
    
    return observers;
}

#pragma mark - automatic updates

- (void)_rz_observeObject:(id)object
{
#if RZDB_AUTOMATIC_UDPATES
    static NSArray *s_KnownUnsupportedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_KnownUnsupportedClasses = @[[NSArray class], [NSSet class], [NSOrderedSet class]];
    });

    if ( ![s_KnownUnsupportedClasses containsObject:[object class]] ) {
        @try {
            [object rz_addTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
        }
        @catch (NSException *exception) {
            RZDBLog(@"RZDataBinding NSArray failed to observe object %@ because KVO is not supported. This is non-fatal, but automatic updates won't work for this object.", object);
        }
    }

#endif
}

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

- (void)_rz_unobserveObject:(id)object force:(BOOL)force
{
    if ( force || [self indexOfObjectIdenticalTo:object] == NSNotFound ) {
        [object rz_removeTarget:self action:@selector(_rz_objectUpdated:) forKeyPathChange:kRZDBObjectUpdateKey];
    }
}

#pragma mark - observer notification

- (void)_rz_notifyObserversOfBatchUpdate:(BOOL)batchUpdating
{
    NSHashTable *observers = [self _rz_arrayObservers];

    [observers.allObjects enumerateObjectsUsingBlock:^(id<RZDBArrayObserver> obs, NSUInteger idx, BOOL *stop) {
        if ( batchUpdating && [obs respondsToSelector:@selector(arrayWillBeginBatchUpdates:)] ) {
            [obs arrayWillBeginBatchUpdates:self];
        }
        else if ( !batchUpdating && [obs respondsToSelector:@selector(arrayDidEndBatchUpdates:)] ) {
            [obs arrayDidEndBatchUpdates:self];
        }
    }];
}

- (void)_rz_willMutate:(RZDBArrayMutation *)mutation
{
    if ( [self _rz_isBatchUpdating] ) {
        [self _rz_addBatchUpdate:mutation];
    }
}

- (void)_rz_didMutate:(RZDBArrayMutation *)mutation
{
    if ( ![self _rz_isBatchUpdating] ) {
        NSHashTable *observers = [self _rz_arrayObservers];
        
        [observers.allObjects enumerateObjectsUsingBlock:^(id<RZDBArrayObserver> observer, NSUInteger idx, BOOL *stop) {
            switch ( mutation.mutationType ) {
                case kRZDBArrayMutationTypeRemove: {
                    if ( [observer respondsToSelector:@selector(array:didRemoveObjects:atIndexes:)] ) {
                        [observer array:self didRemoveObjects:mutation.objects atIndexes:mutation.indexes];
                    }
                    break;
                }

                case kRZDBArrayMutationTypeInsert: {
                    if ( [observer respondsToSelector:@selector(array:didInsertObjectsAtIndexes:)] ) {
                        [observer array:self didInsertObjectsAtIndexes:mutation.indexes];
                    }
                    break;
                }

                case kRZDBArrayMutationTypeMove: {
                    if ( [observer respondsToSelector:@selector(array:didMoveObjectAtIndex:toIndex:)] ) {
                        NSUInteger oldIdx = [mutation.movePath indexAtPosition:0];
                        NSUInteger newIdx = [mutation.movePath indexAtPosition:1];

                        if ( oldIdx != NSNotFound ) {
                            [observer array:self didMoveObjectAtIndex:oldIdx toIndex:newIdx];
                        }
                    }
                    break;
                }

                case kRZDBArrayMutationTypeUpdate: {
                    if ( [observer respondsToSelector:@selector(array:didUpdateObjectsAtIndexes:)] ) {
                        [observer array:self didUpdateObjectsAtIndexes:mutation.indexes];
                    }
                    break;
                }

                default:
                    break;
            }
        }];
    }
}

#pragma mark - batch updating

- (BOOL)_rz_isBatchUpdating
{
    return ([objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue] > 0);
}

- (void)_rz_closeBatchUpdateForce:(BOOL)force
{
    NSUInteger count = [objc_getAssociatedObject(self, kRZDBBatchUpdateNumKey) unsignedIntegerValue];

    if ( count > 0 ) {
        count = force ? 0 : (count - 1);

        id obj = count > 0 ? @(count) : nil;
        objc_setAssociatedObject(self, kRZDBBatchUpdateNumKey, obj, OBJC_ASSOCIATION_RETAIN);
    }

    if ( count == 0 ) {
        [self _rz_sendPendingNotifications];

        [self _rz_setPreBatchObjects:nil];
        [self _rz_setPendingNotifications:nil];

        [self _rz_notifyObserversOfBatchUpdate:NO];
    }
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
    NSMutableIndexSet *removes = pendingNotifications[@(kRZDBArrayMutationTypeRemove)];

    [update.indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        switch ( update.mutationType ) {

            case kRZDBArrayMutationTypeRemove: {
                [updates shiftIndexesStartingAtIndex:idx + 1 by:-1];
                [inserts shiftIndexesStartingAtIndex:idx + 1 by:-1];

                // get index of removed object prior to updates
                NSUInteger remIdx = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:self[idx]];

                if ( remIdx != NSNotFound ) {
                    [removes addIndex:remIdx];
                }
            }
                break;

            case kRZDBArrayMutationTypeInsert: {
                [updates shiftIndexesStartingAtIndex:idx by:1];
                [inserts shiftIndexesStartingAtIndex:idx by:1];

                [inserts addIndex:idx];
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
    NSDictionary *pendingNotifications = [[self _rz_pendingNotifications] copy];

    NSMutableIndexSet *removes = pendingNotifications[@(kRZDBArrayMutationTypeRemove)];
    NSMutableIndexSet *inserts = pendingNotifications[@(kRZDBArrayMutationTypeInsert)];
    NSMutableIndexSet *updates = pendingNotifications[@(kRZDBArrayMutationTypeUpdate)];

    // compute moves separately based on removes/inserts
    NSMutableArray *moves = [NSMutableArray array];

    [[inserts copy] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        id insertedObj = self[idx];

        NSUInteger oldIdx = [[self _rz_preBatchObjects] indexOfObjectIdenticalTo:insertedObj];

        if ( oldIdx != NSNotFound ) {
            [removes removeIndex:oldIdx];
            [inserts removeIndex:idx];

            RZDBArrayMutation *moveMutation = [RZDBArrayMutation moveMutationFromIndex:oldIdx toIndex:idx];
            [moves addObject:moveMutation];
        }
    }];

    if ( removes.count > 0 ) {
        RZDBArrayMutation *removeMutation = [RZDBArrayMutation removeMutationWithObjects:[[self _rz_preBatchObjects] objectsAtIndexes:removes] indexes:removes];

        [self _rz_didMutate:removeMutation];
    }

    if ( inserts.count > 0 ) {
        RZDBArrayMutation *insertMutation = [RZDBArrayMutation insertMutationWithObjects:[self objectsAtIndexes:inserts] indexes:inserts];

        [self _rz_didMutate:insertMutation];
    }

    [moves enumerateObjectsUsingBlock:^(RZDBArrayMutation *moveMutation, NSUInteger idx, BOOL *stop) {
        [self _rz_didMutate:moveMutation];
    }];

    if ( updates.count > 0 ) {
        RZDBArrayMutation *updateMutation = [RZDBArrayMutation updateMutationWithIndexes:updates];

        [self _rz_didMutate:updateMutation];
    }
}

@end

#pragma mark - RZDBMutableArrayTemplate implementation

@implementation RZDBMutableArrayTemplate

- (void)_rz_removeObjectsInRangeSilently:(NSRange)range
{
    struct objc_super rzSuper = _rz_super(self);

    while ( range.length > 0 ) {
        id obj = self[range.location];

        ((void (*)(struct objc_super*, SEL, NSUInteger))objc_msgSendSuper)(&rzSuper, @selector(removeObjectAtIndex:), range.location);

        [self _rz_unobserveObject:obj force:NO];

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
        [self _rz_closeBatchUpdateForce:YES];
        
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

    [self _rz_willMutate:mutation];

    __block NSUInteger numRemoved = 0;

    [indexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        range.location -= numRemoved;
        [self _rz_removeObjectsInRangeSilently:range];
        numRemoved = range.length;
    }];

    [self _rz_didMutate:mutation];
}

- (void)removeObjectsInRange:(NSRange)range
{
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:range];
    NSArray *objects = [self objectsAtIndexes:indexes];
    RZDBArrayMutation *mutation = [RZDBArrayMutation removeMutationWithObjects:objects indexes:indexes];

    [self _rz_willMutate:mutation];

    [self _rz_removeObjectsInRangeSilently:range];

    [self _rz_didMutate:mutation];
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

    [self _rz_willMutate:mutation];

    __block NSUInteger curIndex = [indexes firstIndex];
    __block struct objc_super rzSuper = _rz_super(self);

    [objects enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        ((void (*)(struct objc_super*, SEL, id, NSUInteger))objc_msgSendSuper)(&rzSuper, @selector(insertObject:atIndex:), obj, curIndex);

        [self _rz_observeObject:obj];
        
        curIndex = [indexes indexGreaterThanIndex:curIndex];
    }];

    [self _rz_didMutate:mutation];
}

#pragma mark - replace overrides

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
    if ( self[index] == anObject ) {
        return;
    }

    [self replaceObjectsInRange:NSMakeRange(index, 1) withObjectsFromArray:@[anObject]];
}

- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray *)otherArray
{
    [self replaceObjectsInRange:range withObjectsFromArray:otherArray range:NSMakeRange(0, otherArray.count)];
}

- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray *)otherArray range:(NSRange)otherRange
{
    [self rz_openBatchUpdate];

    NSRange replaceRange = NSMakeRange(range.location, MIN(range.length, otherRange.length));

    NSRange removeRange = NSMakeRange(range.location, MAX(range.length, otherRange.length));
    NSUInteger maxLen = MAX(0, (NSInteger)self.count - replaceRange.location);
    removeRange.length = MIN(removeRange.length, maxLen);

    NSRange insertRange = NSMakeRange(range.location, otherRange.length);

    if ( removeRange.length > 0 ) {
        [self removeObjectsInRange:removeRange];
    }

    if ( insertRange.length > 0 ) {
        [self insertObjects:[otherArray subarrayWithRange:otherRange] atIndexes:[NSIndexSet indexSetWithIndexesInRange:insertRange]];
    }

    [self rz_closeBatchUpdate];
}

- (void)replaceObjectsAtIndexes:(NSIndexSet *)indexes withObjects:(NSArray *)objects
{
    [self rz_openBatchUpdate];

    RZDBArrayMutation *removeMutation = [RZDBArrayMutation removeMutationWithObjects:[self objectsAtIndexes:indexes] indexes:indexes];
    RZDBArrayMutation *insertMutation = [RZDBArrayMutation insertMutationWithObjects:objects indexes:indexes];

    [self _rz_willMutate:removeMutation];
    [self _rz_willMutate:insertMutation];

    __block NSUInteger curIndex = [indexes firstIndex];
    __block struct objc_super rzSuper = _rz_super(self);

    [objects enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        id oldObj = self[curIndex];

        ((void (*)(struct objc_super*, SEL, NSUInteger, id))objc_msgSendSuper)(&rzSuper, @selector(replaceObjectAtIndex:withObject:), curIndex, obj);

        [self _rz_unobserveObject:oldObj force:NO];
        [self _rz_observeObject:obj];

        curIndex = [indexes indexGreaterThanIndex:curIndex];
    }];

    [self _rz_didMutate:removeMutation];
    [self _rz_didMutate:insertMutation];

    [self rz_closeBatchUpdate];
}

#pragma mark - exchange overrides

- (void)exchangeObjectAtIndex:(NSUInteger)idx1 withObjectAtIndex:(NSUInteger)idx2
{
    if ( idx1 == idx2 ) {
        return;
    }
    
    [self rz_openBatchUpdate];

    id obj1 = self[idx1];
    id obj2 = self[idx2];

    [self replaceObjectAtIndex:idx1 withObject:obj2];
    [self replaceObjectAtIndex:idx2 withObject:obj1];
    
    [self rz_closeBatchUpdate];
}

#pragma mark - sort overrides

- (void)sortUsingComparator:(NSComparator)cmptr
{
    [self rz_openBatchUpdate];

    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSComparator))objc_msgSendSuper)(&rzSuper, _cmd, cmptr);

    [self rz_closeBatchUpdate];
}

- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator)cmptr
{
    [self rz_openBatchUpdate];

    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSSortOptions, NSComparator))objc_msgSendSuper)(&rzSuper, _cmd, opts, cmptr);

    [self rz_closeBatchUpdate];
}

- (void)sortUsingDescriptors:(NSArray *)sortDescriptors
{
    [self rz_openBatchUpdate];

    struct objc_super rzSuper = _rz_super(self);
    ((void (*)(struct objc_super*, SEL, NSArray*))objc_msgSendSuper)(&rzSuper, _cmd, sortDescriptors);

    [self rz_closeBatchUpdate];
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
    RZDBArrayMutation *mutation = [[self alloc] init];
    mutation.mutationType = kRZDBArrayMutationTypeRemove;
    mutation.objects = objects;
    mutation.indexes = indexes;

    return mutation;
}

+ (instancetype)insertMutationWithObjects:(NSArray *)objects indexes:(NSIndexSet *)indexes
{
    RZDBArrayMutation *mutation = [[self alloc] init];
    mutation.mutationType = kRZDBArrayMutationTypeInsert;
    mutation.objects = objects;
    mutation.indexes = indexes;

    return mutation;
}

+ (instancetype)moveMutationFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx
{
    NSUInteger indexes[2] = {fromIdx, toIdx};
    NSIndexPath *movePath = [NSIndexPath indexPathWithIndexes:indexes length:2];

    RZDBArrayMutation *mutation = [[self alloc] init];
    mutation.mutationType = kRZDBArrayMutationTypeMove;
    mutation.movePath = movePath;

    return mutation;
}

+ (instancetype)updateMutationWithIndexes:(NSIndexSet *)indexes
{
    RZDBArrayMutation *mutation = [[self alloc] init];
    mutation.mutationType = kRZDBArrayMutationTypeUpdate;
    mutation.indexes = indexes;

    return mutation;
}

@end
