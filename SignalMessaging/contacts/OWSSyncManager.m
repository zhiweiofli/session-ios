//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSSyncManager.h"
#import "Environment.h"
#import "OWSContactsManager.h"
#import "OWSPreferences.h"
#import "OWSProfileManager.h"
#import "OWSReadReceiptManager.h"
#import <PromiseKit/AnyPromise.h>
#import <SignalServiceKit/AppReadiness.h>
#import <SignalServiceKit/DataSource.h>
#import <SignalServiceKit/MIMETypeUtil.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/OWSPrimaryStorage.h>
#import <SignalServiceKit/OWSSyncConfigurationMessage.h>
#import <SignalServiceKit/OWSSyncContactsMessage.h>
#import <SignalServiceKit/OWSSyncGroupsMessage.h>
#import <SignalServiceKit/LKSyncOpenGroupsMessage.h>
#import <SignalServiceKit/SSKEnvironment.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <SignalServiceKit/TSAccountManager.h>
#import <SignalServiceKit/YapDatabaseConnection+OWS.h>
#import <SignalServiceKit/TSContactThread.h>
#import <SignalServiceKit/TSGroupThread.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kSyncManagerCollection = @"kTSStorageManagerOWSSyncManagerCollection";
NSString *const kSyncManagerLastContactSyncKey = @"kTSStorageManagerOWSSyncManagerLastMessageKey";

@interface OWSSyncManager ()

@property (nonatomic, readonly) dispatch_queue_t serialQueue;

@property (nonatomic) BOOL isRequestInFlight;

@end

@implementation OWSSyncManager

+ (instancetype)shared {
    OWSAssertDebug(SSKEnvironment.shared.syncManager);

    return SSKEnvironment.shared.syncManager;
}

- (instancetype)initDefault {
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(signalAccountsDidChange:)
                                                 name:OWSContactsManagerSignalAccountsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileKeyDidChange:)
                                                 name:kNSNotificationName_ProfileKeyDidChange
                                               object:nil];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Dependencies

- (OWSContactsManager *)contactsManager {
    OWSAssertDebug(Environment.shared.contactsManager);

    return Environment.shared.contactsManager;
}

- (OWSIdentityManager *)identityManager {
    OWSAssertDebug(SSKEnvironment.shared.identityManager);

    return SSKEnvironment.shared.identityManager;
}

- (OWSMessageSender *)messageSender {
    OWSAssertDebug(SSKEnvironment.shared.messageSender);

    return SSKEnvironment.shared.messageSender;
}

- (SSKMessageSenderJobQueue *)messageSenderJobQueue
{
    OWSAssertDebug(SSKEnvironment.shared.messageSenderJobQueue);

    return SSKEnvironment.shared.messageSenderJobQueue;
}

- (OWSProfileManager *)profileManager {
    OWSAssertDebug(SSKEnvironment.shared.profileManager);

    return SSKEnvironment.shared.profileManager;
}

- (TSAccountManager *)tsAccountManager
{
    return TSAccountManager.sharedInstance;
}

- (id<OWSTypingIndicators>)typingIndicators
{
    return SSKEnvironment.shared.typingIndicators;
}

#pragma mark - Notifications

- (void)signalAccountsDidChange:(id)notification {
    OWSAssertIsOnMainThread();

    [self sendSyncContactsMessageIfPossible];
}

- (void)profileKeyDidChange:(id)notification {
    OWSAssertIsOnMainThread();

    [self sendSyncContactsMessageIfPossible];
}

#pragma mark -

- (YapDatabaseConnection *)editingDatabaseConnection
{
    return OWSPrimaryStorage.sharedManager.dbReadWriteConnection;
}

- (YapDatabaseConnection *)readDatabaseConnection
{
    return OWSPrimaryStorage.sharedManager.dbReadConnection;
}

#pragma mark - Methods

- (void)sendSyncContactsMessageIfNecessary {
    OWSAssertIsOnMainThread();

    if (!self.serialQueue) {
        _serialQueue = dispatch_queue_create("org.whispersystems.contacts.syncing", DISPATCH_QUEUE_SERIAL);
    }

    dispatch_async(self.serialQueue, ^{
        if (self.isRequestInFlight) {
            // De-bounce.  It's okay if we ignore some new changes;
            // `sendSyncContactsMessageIfPossible` is called fairly
            // often so we'll sync soon.
            return;
        }

        OWSSyncContactsMessage *syncContactsMessage =
            [[OWSSyncContactsMessage alloc] initWithSignalAccounts:self.contactsManager.signalAccounts
                                                   identityManager:self.identityManager
                                                    profileManager:self.profileManager];

        __block NSData *_Nullable messageData;
        __block NSData *_Nullable lastMessageData;
        [self.readDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            messageData = [syncContactsMessage buildPlainTextAttachmentDataWithTransaction:transaction];
            lastMessageData = [transaction objectForKey:kSyncManagerLastContactSyncKey
                                           inCollection:kSyncManagerCollection];
        }];

        if (!messageData) {
            OWSFailDebug(@"Failed to serialize contacts sync message.");
            return;
        }

        if (lastMessageData && [lastMessageData isEqual:messageData]) {
            // Ignore redundant contacts sync message.
            return;
        }

        self.isRequestInFlight = YES;

        // DURABLE CLEANUP - we could replace the custom durability logic in this class
        // with a durable JobQueue.
        DataSource *dataSource = [DataSourceValue dataSourceWithSyncMessageData:messageData];
        [self.messageSender sendTemporaryAttachment:dataSource
            contentType:OWSMimeTypeApplicationOctetStream
            inMessage:syncContactsMessage
            success:^{
                OWSLogInfo(@"Successfully sent contacts sync message.");

                [self.editingDatabaseConnection setObject:messageData
                                                   forKey:kSyncManagerLastContactSyncKey
                                             inCollection:kSyncManagerCollection];

                dispatch_async(self.serialQueue, ^{
                    self.isRequestInFlight = NO;
                });
            }
            failure:^(NSError *error) {
                OWSLogError(@"Failed to send contacts sync message with error: %@", error);

                dispatch_async(self.serialQueue, ^{
                    self.isRequestInFlight = NO;
                });
            }];
    });
}

- (void)sendSyncContactsMessageIfPossible {
    OWSAssertIsOnMainThread();

    if (!self.contactsManager.isSetup) {
        // Don't bother if the contacts manager hasn't finished setup.
        return;
    }

    if ([TSAccountManager sharedInstance].isRegisteredAndReady) {
        [self sendSyncContactsMessageIfNecessary];
    }
}

- (void)sendConfigurationSyncMessage {
    [AppReadiness runNowOrWhenAppDidBecomeReady:^{
        if (!self.tsAccountManager.isRegisteredAndReady) {
            return;
        }        
        
        NSUserDefaults *userDefaults = NSUserDefaults.standardUserDefaults;
        BOOL hasLaunchedOnce = [userDefaults boolForKey:@"hasLaunchedOnce"];
        if (hasLaunchedOnce) { // FIXME: Quick and dirty workaround to not do this on initial launch
            [self sendConfigurationSyncMessage_AppReady];
        }
    }];
}

- (void)sendConfigurationSyncMessage_AppReady {
    DDLogInfo(@"");

    if (![TSAccountManager sharedInstance].isRegisteredAndReady) {
        return;
    }

    BOOL areReadReceiptsEnabled = SSKEnvironment.shared.readReceiptManager.areReadReceiptsEnabled;
    BOOL showUnidentifiedDeliveryIndicators = Environment.shared.preferences.shouldShowUnidentifiedDeliveryIndicators;
    BOOL showTypingIndicators = self.typingIndicators.areTypingIndicatorsEnabled;
    BOOL sendLinkPreviews = SSKPreferences.areLinkPreviewsEnabled;

    OWSSyncConfigurationMessage *syncConfigurationMessage =
        [[OWSSyncConfigurationMessage alloc] initWithReadReceiptsEnabled:areReadReceiptsEnabled
                                      showUnidentifiedDeliveryIndicators:showUnidentifiedDeliveryIndicators
                                                    showTypingIndicators:showTypingIndicators
                                                        sendLinkPreviews:sendLinkPreviews];

    [self.editingDatabaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
        [self.messageSenderJobQueue addMessage:syncConfigurationMessage transaction:transaction];
    }];
}

#pragma mark - Local Sync

- (AnyPromise *)syncLocalContact
{
    NSString *localNumber = self.tsAccountManager.localNumber;
    SignalAccount *signalAccount = [[SignalAccount alloc] initWithRecipientId:localNumber];
    signalAccount.contact = [Contact new];

    return [self syncContactsForSignalAccounts:@[ signalAccount ]];
}

- (AnyPromise *)syncContact:(NSString *)hexEncodedPubKey transaction:(YapDatabaseReadTransaction *)transaction
{
    TSContactThread *thread = [TSContactThread getThreadWithContactId:hexEncodedPubKey transaction:transaction];
    if (thread != nil && thread.isContactFriend) {
        return [self syncContactsForSignalAccounts:@[[[SignalAccount alloc] initWithRecipientId:hexEncodedPubKey]]];
    }
    return [AnyPromise promiseWithValue:@1];
}

- (AnyPromise *)syncAllContacts
{
    NSMutableArray<SignalAccount *> *friends = @[].mutableCopy;
    NSMutableArray<AnyPromise *> *promises = @[].mutableCopy;
    [TSContactThread enumerateCollectionObjectsUsingBlock:^(TSContactThread *thread, BOOL *stop) {
        NSString *hexEncodedPublicKey = thread.contactIdentifier;
        if (hexEncodedPublicKey != nil && thread.isContactFriend && thread.shouldThreadBeVisible && !thread.isForceHidden) {
            [friends addObject:[[SignalAccount alloc] initWithRecipientId:hexEncodedPublicKey]];
        }
    }];
    [friends addObject:[[SignalAccount alloc] initWithRecipientId:self.tsAccountManager.localNumber]];
    NSMutableArray<SignalAccount *> *signalAccounts = @[].mutableCopy;
    for (SignalAccount *contact in friends) {
        [signalAccounts addObject:contact];
        if (signalAccounts.count >= 3) {
            [promises addObject:[self syncContactsForSignalAccounts:[signalAccounts copy]]];
            [signalAccounts removeAllObjects];
        }
    }
    if (signalAccounts.count > 0) {
        [promises addObject:[self syncContactsForSignalAccounts:signalAccounts]];
    }
    AnyPromise *promise = PMKJoin(promises);
    [promise retainUntilComplete];
    return promise;
}

- (AnyPromise *)syncContactsForSignalAccounts:(NSArray<SignalAccount *> *)signalAccounts
{
    OWSSyncContactsMessage *syncContactsMessage = [[OWSSyncContactsMessage alloc] initWithSignalAccounts:signalAccounts identityManager:self.identityManager profileManager:self.profileManager];
    AnyPromise *promise = [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
        [self.messageSender sendMessage:syncContactsMessage
            success:^{
                OWSLogInfo(@"Successfully sent contacts sync message.");
                resolve(@(1));
            }
            failure:^(NSError *error) {
                OWSLogError(@"Failed to send contacts sync message with error: %@.", error);
                resolve(error);
            }];
    }];
    [promise retainUntilComplete];
    return promise;
}

- (AnyPromise *)syncAllGroups
{
    NSMutableArray<TSGroupThread *> *groupThreads = @[].mutableCopy;
    NSMutableArray<AnyPromise *> *promises = @[].mutableCopy;
    [TSGroupThread enumerateCollectionObjectsUsingBlock:^(id obj, BOOL *stop) {
        if (![obj isKindOfClass:[TSGroupThread class]]) {
            if (![obj isKindOfClass:[TSContactThread class]]) { // FIXME: Isn't this redundant?
                OWSLogWarn(@"Ignoring non-group thread in thread collection: %@.", obj);
            }
            return;
        }
        TSGroupThread *thread = (TSGroupThread *)obj;
        if (thread.groupModel.groupType == closedGroup && thread.shouldThreadBeVisible && !thread.isForceHidden) {
            [groupThreads addObject:thread];
        }
    }];
    for (TSGroupThread *groupThread in groupThreads) {
        [promises addObject:[self syncGroupForThread:groupThread]];
    }
    AnyPromise *promise = PMKJoin(promises);
    [promise retainUntilComplete];
    return promise;
}

- (AnyPromise *)syncGroupForThread:(TSGroupThread *)thread
{
    OWSSyncGroupsMessage *syncGroupsMessage = [[OWSSyncGroupsMessage alloc] initWithGroupThread:thread];
    AnyPromise *promise = [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
        [self.messageSender sendMessage:syncGroupsMessage
            success:^{
                OWSLogInfo(@"Successfully sent group sync message.");
                resolve(@(1));
            }
            failure:^(NSError *error) {
                OWSLogError(@"Failed to send group sync message due to error: %@.", error);
                resolve(error);
            }];
    }];
    [promise retainUntilComplete];
    return promise;
}

- (AnyPromise *)syncAllOpenGroups
{
    LKSyncOpenGroupsMessage *syncOpenGroupsMessage = [[LKSyncOpenGroupsMessage alloc] init];
    AnyPromise *promise = [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
        [self.messageSender sendMessage:syncOpenGroupsMessage
            success:^{
                OWSLogInfo(@"Successfully sent open group sync message.");
                resolve(@(1));
            }
            failure:^(NSError *error) {
                OWSLogError(@"Failed to send open group sync message due to error: %@.", error);
                resolve(error);
            }];
    }];
    [promise retainUntilComplete];
    return promise;
}

@end

NS_ASSUME_NONNULL_END
