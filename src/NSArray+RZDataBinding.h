//
//  NSArray+RZDataBinding.h
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

@import Foundation;

typedef NS_ENUM(NSUInteger, RZDBArrayMutationType) {
    kRZDBArrayMutationTypeUnknown   = 0,
    kRZDBArrayMutationTypeRemove,
    kRZDBArrayMutationTypeInsert,
    kRZDBArrayMutationTypeMove, // only used internally
    kRZDBArrayMutationTypeUpdate
};

@protocol RZDBArrayObserver <NSObject>

@required
- (void)array:(NSArray *)array didChangeContents:(RZDBArrayMutationType)mutationType atIndexes:(NSIndexSet *)indexes;
- (void)array:(NSArray *)array didMoveObjectAtIndex:(NSUInteger)oldIndex toIndex:(NSUInteger)newIndex;

@optional
- (void)array:(NSArray *)array willChangeContents:(RZDBArrayMutationType)mutationType atIndexes:(NSIndexSet *)indexes;
- (void)array:(NSArray *)array willMoveObjectAtIndex:(NSUInteger)oldIndex toIndex:(NSUInteger)newIndex;

- (void)arrayWillBeginBatchUpdates:(NSArray *)array;
- (void)arrayDidEndBatchUpdates:(NSArray *)array;

@end

@interface NSArray (RZDataBinding)

- (void)rz_addObserver:(id<RZDBArrayObserver>)observer;
- (void)rz_removeObserver:(id<RZDBArrayObserver>)observer;

- (void)rz_registerForObjectUpdateNotificationsNamed:(NSArray *)names;
- (void)rz_unregisterForObjectUpdateNotificationsNamed:(NSArray *)names;
- (void)rz_unregisterForAllObjectUpdateNotifications;

- (void)rz_beginBatchUpdates;
- (void)rz_endBatchUpdates:(BOOL)force;

@end

@interface NSMutableArray (RZDataBinding)

- (NSArray *)rz_immutableProxy;

@end
