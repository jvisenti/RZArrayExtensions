//
//  RZDBCollectionViewDataSource.h
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

@import UIKit;

typedef NSString* (^RZDBReuseIdentifierBlock)(id object);

@protocol RZDBCollectionViewDataSourceDelegate <NSObject>

@required
- (void)collectionView:(UICollectionView *)collectionView updateCell:(UICollectionViewCell *)cell forObject:(id)object atIndexPath:(NSIndexPath *)indexPath;

@optional
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForObject:(id)object atIndexPath:(NSIndexPath *)indexPath;
- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath;

@end

@interface RZDBCollectionViewDataSource : NSObject <UICollectionViewDataSource>

@property (weak, nonatomic, readonly) UICollectionView *collectionView;
@property (strong, nonatomic) NSArray *backingArray;

@property (assign, nonatomic) BOOL animateCollectionViewChanges;
@property (assign, nonatomic) BOOL reloadAfterAnimation;

@property (weak, nonatomic) id<RZDBCollectionViewDataSourceDelegate> delegate;

- (instancetype)initWithCollectionView:(UICollectionView *)collectionView backingArray:(NSArray *)backingArray delegate:(id<RZDBCollectionViewDataSourceDelegate>)delegate;

- (void)registerReuseIdentifier:(NSString *)identifier forClass:(Class)objectClass;
- (void)registerReuseIdentifierBlock:(RZDBReuseIdentifierBlock)identifierBlock forClass:(Class)objectClass;

@end
