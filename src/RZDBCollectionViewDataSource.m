//
//  RZDBCollectionViewDataSource.m
//
//  Created by Rob Visentin on 12/6/14.
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

#import "RZDBCollectionViewDataSource.h"
#import "NSArray+RZDataBinding.h"

typedef void (^RZDBCollectionViewUpdateBlock)(void);

@interface RZDBCollectionViewDataSource () <RZDBArrayObserver> {
    struct {
        BOOL respondsToCellForObject:1;
        BOOL respondsToSupplementaryView:1;
    } _delegateFlags;
}

@property (weak, nonatomic, readwrite) UICollectionView *collectionView;

@property (strong, nonatomic) NSMutableDictionary *reuseIdentifiersByClass;

@property (assign, nonatomic) BOOL batchUpdating;
@property (strong, nonatomic) NSMutableArray *batchUpdates;
@property (strong, nonatomic) NSMutableArray *postBatchUpdates;

@end

@implementation RZDBCollectionViewDataSource

#pragma mark - lifecycle

- (instancetype)initWithCollectionView:(UICollectionView *)collectionView backingArray:(NSArray *)backingArray delegate:(id<RZDBCollectionViewDataSourceDelegate>)delegate
{
    NSParameterAssert(collectionView);
    
    self = [super init];
    if ( self ) {
        self.delegate = delegate;
        self.backingArray = backingArray;
        
        self.animateCollectionViewChanges = YES;
        
        self.reuseIdentifiersByClass = [NSMutableDictionary dictionary];
        
        self.collectionView = collectionView;
        self.collectionView.dataSource = self;
    }
    return self;
}

- (void)dealloc
{
    [self.backingArray rz_removeObserver:self];
}

#pragma mark - public methods

- (void)setBackingArray:(NSMutableArray *)backingArray
{
    if ( backingArray != _backingArray ) {
        [_backingArray rz_removeObserver:self];
        _backingArray = backingArray;
        [_backingArray rz_addObserver:self];
        
        [self.collectionView reloadData];
    }
}

- (void)setDelegate:(id<RZDBCollectionViewDataSourceDelegate>)delegate
{
    if ( delegate != _delegate ) {
        _delegate = delegate;
        
        _delegateFlags.respondsToCellForObject = [_delegate respondsToSelector:@selector(collectionView:cellForObject:atIndexPath:)];
        _delegateFlags.respondsToSupplementaryView = [_delegate respondsToSelector:@selector(collectionView:viewForSupplementaryElementOfKind:atIndexPath:)];
    }
}

- (void)registerReuseIdentifier:(NSString *)identifier forClass:(Class)objectClass
{
    Class keyClass = [self classKeyForClass:objectClass];
    self.reuseIdentifiersByClass[(id<NSCopying>)keyClass] = identifier;
}

- (void)registerReuseIdentifierBlock:(RZDBReuseIdentifierBlock)identifierBlock forClass:(Class)objectClass
{
    Class keyClass = [self classKeyForClass:objectClass];
    self.reuseIdentifiersByClass[(id<NSCopying>)keyClass] = [identifierBlock copy];
}

#pragma mark - private methods

- (Class)classKeyForClass:(Class)class
{
    Class keyClass = class;
    
    if ( [class isSubclassOfClass:[NSString class]] ) {
        keyClass = [NSString class];
    }
    else if ( [class isSubclassOfClass:[NSArray class]] ) {
        keyClass = [NSArray class];
    }
    else if ( [class isSubclassOfClass:[NSSet class]] ) {
        keyClass = [NSSet class];
    }
    else if ( [class isSubclassOfClass:[NSDictionary class]] ) {
        keyClass = [NSDictionary class];
    }
    
    return keyClass;
}

- (void)setBatchUpdating:(BOOL)batchUpdating
{
    if ( batchUpdating != _batchUpdating ) {
        _batchUpdating = batchUpdating;
        
        if ( batchUpdating ) {
            self.batchUpdates = [NSMutableArray array];
            self.postBatchUpdates = [NSMutableArray array];
        }
        else {
            if ( self.animateCollectionViewChanges ) {
                if ( self.batchUpdates.count > 0 ) {
                    [self.collectionView performBatchUpdates:^{
                        [self.batchUpdates enumerateObjectsUsingBlock:^(RZDBCollectionViewUpdateBlock updateBlock, NSUInteger idx, BOOL *stop) {
                            updateBlock();
                        }];
                    } completion:^(BOOL finished) {
                        if ( finished ) {
                            self.batchUpdates = nil;
                            
                            [self runPostBatchUpdates];
                            
                            if ( self.reloadAfterAnimation ) {
                                [self.collectionView reloadData];
                            }
                        }
                    }];
                }
                else {
                    [self runPostBatchUpdates];
                }
            }
            else {
                self.batchUpdates = nil;
                [self runPostBatchUpdates];

                [self.collectionView reloadData];
            }
        }
    }
}

- (NSArray *)indexPathsFromIndexSet:(NSIndexSet *)indexes
{
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:indexes.count];

    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:idx inSection:0];
        [indexPaths addObject:indexPath];
    }];

    return indexPaths;
}

- (void)runUpdateBlock:(RZDBCollectionViewUpdateBlock)updateBlock postBatchUpdates:(BOOL)postBatch
{
    if ( self.collectionView.window == nil ) {
        return;
    }

    if ( self.batchUpdating ) {
        if ( postBatch ) {
            [self.postBatchUpdates addObject:[updateBlock copy]];
        }
        else {
            [self.batchUpdates addObject:[updateBlock copy]];
        }
    }
    else {
        updateBlock();
    }
}

- (void)runPostBatchUpdates
{
    [self.postBatchUpdates enumerateObjectsUsingBlock:^(RZDBCollectionViewUpdateBlock updateBlock, NSUInteger idx, BOOL *stop) {
        updateBlock();
    }];

    self.postBatchUpdates = nil;
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self.backingArray.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = nil;
    
    id object = self.backingArray[indexPath.item];
    
    Class keyClass = [self classKeyForClass:[object class]];
    id identifier = self.reuseIdentifiersByClass[(id<NSCopying>)keyClass];
    
    if ( identifier != nil ) {
        NSString *reuseId = nil;

        if ( [identifier isKindOfClass:[NSString class]] ) {
            reuseId = identifier;
        }
        else {
            reuseId = ((RZDBReuseIdentifierBlock)identifier)(object);
        }
        
        cell = [collectionView dequeueReusableCellWithReuseIdentifier:reuseId forIndexPath:indexPath];
    }
    else if ( _delegateFlags.respondsToCellForObject ) {
        cell = [self.delegate collectionView:self.collectionView cellForObject:object atIndexPath:indexPath];
    }
    
    if ( cell == nil ) {
        [NSException raise:NSInternalInconsistencyException format:@"[%@] must either have a valid reuse identifier registered, or its delegate must implement %@ and suppy a non-nil cell.", [self class], NSStringFromSelector(@selector(collectionView:cellForObject:atIndexPath:))];
    }
    else {
        [self.delegate collectionView:collectionView updateCell:cell forObject:object atIndexPath:indexPath];
    }
    
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    UICollectionReusableView *view = nil;

    if ( _delegateFlags.respondsToSupplementaryView ) {
        view = [self.delegate collectionView:collectionView viewForSupplementaryElementOfKind:kind atIndexPath:indexPath];
    }
    
    return view;
}

#pragma mark - RZDBArrayObserver

- (void)arrayWillBeginBatchUpdates:(NSArray *)array
{
    self.batchUpdating = YES;
}

- (void)array:(NSArray *)array didRemoveObjects:(NSArray *)objects atIndexes:(NSIndexSet *)indexes
{
    if ( self.animateCollectionViewChanges ) {
        NSArray *indexPaths = [self indexPathsFromIndexSet:indexes];

        RZDBCollectionViewUpdateBlock updateBlock = ^{
            [self.collectionView deleteItemsAtIndexPaths:indexPaths];
        };

        [self runUpdateBlock:updateBlock postBatchUpdates:NO];
    }
    else if ( !self.batchUpdating ) {
        [self.collectionView reloadData];
    }
}

- (void)array:(NSArray *)array didInsertObjectsAtIndexes:(NSIndexSet *)indexes
{
    if ( self.animateCollectionViewChanges ) {
        NSArray *indexPaths = [self indexPathsFromIndexSet:indexes];

        RZDBCollectionViewUpdateBlock updateBlock = ^{
            [self.collectionView insertItemsAtIndexPaths:indexPaths];
        };

        [self runUpdateBlock:updateBlock postBatchUpdates:NO];
    }
    else if ( !self.batchUpdating ) {
        [self.collectionView reloadData];
    }
}

- (void)array:(NSArray *)array didMoveObjectAtIndex:(NSUInteger)oldIndex toIndex:(NSUInteger)newIndex
{
    if ( self.animateCollectionViewChanges ) {
        NSIndexPath *oldPath = [NSIndexPath indexPathForItem:oldIndex inSection:0];
        NSIndexPath *newPath = [NSIndexPath indexPathForItem:newIndex inSection:0];

        RZDBCollectionViewUpdateBlock updateBlock = ^{
            [self.collectionView moveItemAtIndexPath:oldPath toIndexPath:newPath];
        };

        [self runUpdateBlock:updateBlock postBatchUpdates:NO];
    }
    else if ( !self.batchUpdating ) {
        [self.collectionView reloadData];
    }
}

- (void)array:(NSArray *)array didUpdateObjectsAtIndexes:(NSIndexSet *)indexes
{
    if ( self.animateCollectionViewChanges ) {
        NSArray *indexPaths = [self indexPathsFromIndexSet:indexes];

        RZDBCollectionViewUpdateBlock updateBlock = ^{
            [indexPaths enumerateObjectsUsingBlock:^(NSIndexPath *indexPath, NSUInteger idx, BOOL *stop) {
                UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];

                if ( cell != nil ) {
                    id object = self.backingArray[indexPath.item];
                    [self.delegate collectionView:self.collectionView updateCell:cell forObject:object atIndexPath:indexPath];
                }
            }];
        };

        [self runUpdateBlock:updateBlock postBatchUpdates:YES];
    }
    else if ( !self.batchUpdating ) {
        [self.collectionView reloadData];
    }
}

- (void)arrayDidEndBatchUpdates:(NSArray *)array
{
    self.batchUpdating = NO;
}

@end
