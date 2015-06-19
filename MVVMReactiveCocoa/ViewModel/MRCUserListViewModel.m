//
//  MRCUserListViewModel.m
//  MVVMReactiveCocoa
//
//  Created by leichunfeng on 15/6/8.
//  Copyright (c) 2015年 leichunfeng. All rights reserved.
//

#import "MRCUserListViewModel.h"
#import "MRCUserListItemViewModel.h"
#import "MRCUserDetailViewModel.h"

@interface MRCUserListViewModel ()

@property (strong, nonatomic) OCTUser *user;
@property (assign, nonatomic, readwrite) MRCUserListViewModelType type;
@property (assign, nonatomic, readwrite) BOOL isCurrentUser;
@property (strong, nonatomic) RACCommand *operationCommand;

@end

@implementation MRCUserListViewModel

- (instancetype)initWithServices:(id<MRCViewModelServices>)services params:(id)params {
    self = [super initWithServices:services params:params];
    if (self) {
        self.user = params[@"user"];
    }
    return self;
}

- (void)initialize {
    [super initialize];
    
    self.type = [self.params[@"type"] unsignedIntegerValue];
    if (self.type == MRCUserListViewModelTypeFollowers) {
        self.title = @"Followers";
    } else if (self.type == MRCUserListViewModelTypeFollowing) {
        self.title = @"Following";
    }
    
    self.shouldPullToRefresh = YES;
    self.shouldInfiniteScrolling = YES;
    
    @weakify(self)
    self.didSelectCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(NSIndexPath *indexPath) {
        @strongify(self)
        MRCUserListItemViewModel *itemViewModel = self.dataSource[indexPath.section][indexPath.row];
        
        MRCUserDetailViewModel *viewModel = [[MRCUserDetailViewModel alloc] initWithServices:self.services
                                                                                      params:@{ @"user": itemViewModel.user }];
        [self.services pushViewModel:viewModel animated:YES];
       
        return [RACSignal empty];
    }];
    
    self.operationCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(MRCUserListItemViewModel *viewModel) {
        @strongify(self)
        if (viewModel.followingStatus == OCTUserFollowingStatusYES) {
            return [[self.services client] followUser:viewModel.user];
        } else if (viewModel.followingStatus == OCTUserFollowingStatusNO) {
            return [[self.services client] unfollowUser:viewModel.user];
        }
        return [RACSignal empty];
    }];

    self.operationCommand.allowsConcurrentExecution = YES;
    
    RACSignal *fetchLocalDataSignal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self)
        if (self.isCurrentUser) {
            if (self.type == MRCUserListViewModelTypeFollowers) {
                [subscriber sendNext:[OCTUser mrc_fetchFollowersWithPage:1 perPage:self.perPage]];
            } else if (self.type == MRCUserListViewModelTypeFollowing) {
                [subscriber sendNext:[OCTUser mrc_fetchFollowingWithPage:1 perPage:self.perPage]];
            }
        }
        return nil;
    }];
    
    RACSignal *requestRemoteDataSignal = self.requestRemoteDataCommand.executionSignals.flatten;
    
    RAC(self, users) = [fetchLocalDataSignal merge:requestRemoteDataSignal];
    
    RAC(self, dataSource) = [RACObserve(self, users) map:^(NSArray *users) {
        @strongify(self)
        return [self dataSourceWithUsers:users];
    }];
}

- (BOOL)isCurrentUser {
    return [self.user.objectID isEqualToString:[OCTUser mrc_currentUserId]];
}

- (RACSignal *)requestRemoteDataSignalWithPage:(NSUInteger)page {
    if (self.type == MRCUserListViewModelTypeFollowers) {
        return [[[[[self.services
        	client]
            fetchFollowersWithUser:self.user page:page perPage:self.perPage].collect
        	map:^(NSArray *users) {
                for (OCTUser *user in users) {
                    if (self.isCurrentUser) user.followerStatus = OCTUserFollowerStatusYES;
                }
                return users;
            }]
        	map:^(NSArray *users) {
                if (page == 1) {
                    for (OCTUser *user in users) {
                        for (OCTUser *preUser in self.users) {
                            if ([user.objectID isEqualToString:preUser.objectID]) {
                                user.followingStatus = preUser.followingStatus;
                                break;
                            }
                        }
                    }
                } else {
                    users = @[ (self.users ?: @[]).rac_sequence, users.rac_sequence ].rac_sequence.flatten.array;
                }
                return users;
            }]
        	doNext:^(NSArray *users) {
                if (self.isCurrentUser) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [OCTUser mrc_saveOrUpdateUsers:self.users];
                        [OCTUser mrc_saveOrUpdateFollowerStatusWithUsers:self.users];
                    });
                }
            }];
    } else if (self.type == MRCUserListViewModelTypeFollowing) {
        return [[[[[self.services
            client]
            fetchFollowingWithUser:self.user page:page perPage:self.perPage].collect
            map:^(NSArray *users) {
                for (OCTUser *user in users) {
                    if (self.isCurrentUser) user.followingStatus = OCTUserFollowingStatusYES;
                }
                return users;
            }]
        	map:^(NSArray *users) {
                if (page != 1) {
                    users = @[ (self.users ?: @[]).rac_sequence, users.rac_sequence ].rac_sequence.flatten.array;
                }
                return users;
            }]
        	doNext:^(NSArray *users) {
                if (self.isCurrentUser) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [OCTUser mrc_saveOrUpdateUsers:self.users];
                        [OCTUser mrc_saveOrUpdateFollowingStatusWithUsers:self.users];
                    });
                }
            }];
    }
    return [RACSignal empty];
}

- (NSArray *)dataSourceWithUsers:(NSArray *)users {
    if (users.count == 0) return nil;
    
    @weakify(self)
    NSArray *viewModels = [users.rac_sequence map:^(OCTUser *user) {
        @strongify(self)
        MRCUserListItemViewModel *viewModel = [[MRCUserListItemViewModel alloc] initWithUser:user];
        
        if (user.followingStatus == OCTUserFollowingStatusUnknown) {
            @weakify(viewModel)
            [[[[self.services
                client]
                hasFollowUser:user]
                takeUntil:viewModel.rac_willDeallocSignal]
                subscribeNext:^(NSNumber *isFollowing) {
                    @strongify(viewModel)
                    if (isFollowing.boolValue) {
                        user.followingStatus = OCTUserFollowingStatusYES;
                        viewModel.followingStatus = OCTUserFollowingStatusYES;
                    } else {
                        user.followingStatus = OCTUserFollowingStatusNO;
                        viewModel.followingStatus = OCTUserFollowingStatusNO;
                    }
             }];
        }
        viewModel.operationCommand = self.operationCommand;
        
        return viewModel;
    }].array;
    
    return @[ viewModels ];
}

@end