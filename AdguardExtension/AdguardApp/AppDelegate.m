/**
    This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
    Copyright © Adguard Software Limited. All rights reserved.
 
    Adguard for iOS is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
 
    Adguard for iOS is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
 
    You should have received a copy of the GNU General Public License
    along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

#import <SafariServices/SafariServices.h>
#import "ACommons/ACLang.h"
#import "ACommons/ACSystem.h"
#import "ACommons/ACNetwork.h"
#import "ADomain/ADomain.h"
#import "AppDelegate.h"
#import "AESAntibanner.h"
#import "AESFilterConverter.h"
#import "AESharedResources.h"
#import "AESProductSchemaManager.h"
#import "ACDnsUtils.h"

#import "Adguard-Swift.h"

#define SAFARI_BUNDLE_ID                        @"com.apple.mobilesafari"
#define SAFARI_VC_BUNDLE_ID                     @"com.apple.SafariViewService"

#define DNS_FILTERS_CHECK_LIMIT                 21600 // 6 hours

NSString *AppDelegateStartedUpdateNotification = @"AppDelegateStartedUpdateNotification";
NSString *AppDelegateFinishedUpdateNotification = @"AppDelegateFinishedUpdateNotification";
NSString *AppDelegateFailuredUpdateNotification = @"AppDelegateFailuredUpdateNotification";
NSString *AppDelegateUpdatedFiltersKey = @"AppDelegateUpdatedFiltersKey";
NSString *ShowCommonAlertNotification = @"ShowCommonAlert";

NSString *OpenDnsSettingsSegue = @"dns_settings";

typedef void (^AETFetchCompletionBlock)(UIBackgroundFetchResult);
typedef void (^AEDownloadsCompletionBlock)();

typedef enum : NSUInteger {
    AEUpdateNotStarted,
    AEUpdateStarted,
    AEUpdateNewData,
    AEUpdateFailed,
    AEUpdateNoData
} AEUpdateResult;

static NSTimeInterval lastCheckTime;

@interface AppDelegate (){
    
    AETFetchCompletionBlock _fetchCompletion;
    AEDownloadsCompletionBlock _downloadCompletion;
    NSArray *_updatedFilters;
    AESharedResources *_resources;
    id<AntibannerControllerProtocol> _antibannerController;
    id<AESAntibannerProtocol> _antibanner;
    ContentBlockerService* _contentBlockerService;
    PurchaseService* _purchaseService;
    id<DnsFiltersServiceProtocol> _dnsFiltersService;
    id<ACNNetworkingProtocol> _networking;
    ConfigurationService *_configuration;
    id<ThemeServiceProtocol> _theme;
    
    BOOL _activateWithOpenUrl;
    
    AppDelegateHelper* helper;
}

@property AEUpdateResult antibanerUpdateResult;
@property AEUpdateResult blockingSubscriptionsUpdateResult;

@end

@implementation AppDelegate

/////////////////////////////////////////////////////////////////////
#pragma mark Application Init
/////////////////////////////////////////////////////////////////////

- (instancetype)init {
    self = [super init];
    
    [StartupService start];
    _resources = [ServiceLocator.shared getSetviceWithTypeName:@"AESharedResourcesProtocol"];
    _antibannerController = [ServiceLocator.shared getSetviceWithTypeName:@"AntibannerControllerProtocol"];
    _contentBlockerService = [ServiceLocator.shared getSetviceWithTypeName:@"ContentBlockerService"];
    _purchaseService = [ServiceLocator.shared getSetviceWithTypeName:@"PurchaseServiceProtocol"];
    _antibanner = [ServiceLocator.shared getSetviceWithTypeName:@"AESAntibannerProtocol"];
    _dnsFiltersService = [ServiceLocator.shared getSetviceWithTypeName:@"DnsFiltersServiceProtocol"];
    _networking = [ServiceLocator.shared getSetviceWithTypeName:@"ACNNetworking"];
    _configuration = [ServiceLocator.shared getSetviceWithTypeName:@"ConfigurationService"];
    _theme = [ServiceLocator.shared getSetviceWithTypeName:@"ThemeServiceProtocol"];
    
    helper = [[AppDelegateHelper alloc] initWithAppDelegate:self];
    
    return self;
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions{
    
    @autoreleasepool {
        
        //------------- Preparing for start application. Stage 1. -----------------
        
        BOOL succeeded = [helper application:application willFinishLaunchingWithOptions:launchOptions];

        // Init Logger
        [[ACLLogger singleton] initLogger:[_resources sharedAppLogsURL]];
        
#if DEBUG
        [[ACLLogger singleton] setLogLevel:ACLLDebugLevel];
#endif
        
        DDLogInfo(@"Application started. Version: %@", [ADProductInfo buildVersion]);
        
        DDLogInfo(@"(AppDelegate) Preparing for start application. Stage 1.");
        
        _fetchCompletion = nil;
        _downloadCompletion = nil;
        _activateWithOpenUrl = NO;
        self.userDefaultsInitialized = NO;
        
        //------------ Interface Tuning -----------------------------------
        self.window.backgroundColor = [UIColor clearColor];
        
        
        if (application.applicationState != UIApplicationStateBackground) {
            [_purchaseService checkPremiumStatusChanged];
        }
        
        return succeeded;
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    [helper applicationDidFinishLaunching:application];
    
    //------------- Preparing for start application. Stage 2. -----------------
    DDLogInfo(@"(AppDelegate) Preparing for start application. Stage 2.");
    
    //------------ Subscribe to Antibanner notification -----------------------------
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerFailuredUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerFinishedUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerStartedUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerDidntStartUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerUpdateFilterRulesNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(antibannerNotify:) name:ASAntibannerUpdatePartCompletedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showAlertNotification:) name:ShowCommonAlertNotification object:nil];
    
    //---------------------- Set period for checking filters ---------------------
    [self setPeriodForCheckingFilters];
    
    ASSIGN_WEAK(self);
    [[NSNotificationCenter defaultCenter] addObserverForName: ConfigurationService.themeChangeNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        ASSIGN_STRONG(self);
        USE_STRONG(self).window.backgroundColor = _theme.backgroundColor;
    }];
    
    return YES;
}


- (void)setPeriodForCheckingFilters{
    
    NSTimeInterval interval = AS_FETCH_UPDATE_STATUS_PERIOD;
    if (interval < UIApplicationBackgroundFetchIntervalMinimum) {
        interval = UIApplicationBackgroundFetchIntervalMinimum;
    }
    
    [[UIApplication sharedApplication] setMinimumBackgroundFetchInterval:interval];
    DDLogInfo(@"(AppDelegate) Set background fetch interval: %f", interval);
    
}

/////////////////////////////////////////////////////////////////////
#pragma mark Application Delegate Methods
/////////////////////////////////////////////////////////////////////


- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    
    DDLogInfo(@"(AppDelegate) applicationWillResignActive.");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    
    DDLogInfo(@"(AppDelegate) applicationDidEnterBackground.");
    [_resources synchronizeSharedDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    DDLogInfo(@"(AppDelegate) applicationWillEnterForeground.");
    [_antibanner applicationWillEnterForeground];
    
    ConfigurationService* configuration = [ServiceLocator.shared getSetviceWithTypeName:@"ConfigurationService"];
    [configuration checkContentBlockerEnabled];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    
    DDLogInfo(@"(AppDelegate) applicationDidBecomeActive.");
    
    [helper applicationDidBecomeActive: application];
    
    // If theme mode is System Default gets current style
    [self setAppInterfaceStyle];
    
    [_antibannerController onReady:^(id<AESAntibannerProtocol> _Nonnull antibanner) {
        [antibanner repairUpdateStateWithCompletionBlock:^{
            
            if (_activateWithOpenUrl) {
                _activateWithOpenUrl = NO;
                DDLogInfo(@"(AppDelegate - applicationDidBecomeActive) Update process did not start because app activated with open URL.");
                return;
            }
            
            if (antibanner.updatesRightNow) {
                DDLogInfo(@"(AppDelegate - applicationDidBecomeActive) Update process did not start because it is performed right now.");
                return;
            }
            
            //Entry point for updating of the filters
            if ([self checkAutoUpdateConditions]) {
                [self invalidateAntibanner:NO interactive:YES];
            }
        }];
        
    }];
    
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    
    DDLogInfo(@"(AppDelegate) applicationWillTerminate.");
    [_resources synchronizeSharedDefaults];
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(nonnull void (^)(UIBackgroundFetchResult))completionHandler{
    @autoreleasepool {
        
        [helper performFetch];
        DDLogInfo(@"(AppDelegate) application perform Fetch.");
        
        if (_fetchCompletion) {
            
            // In this case we receive fetch event when previous event still not processed.
            DDLogInfo(@"(AppDelegate) Previous Fetch still not processed.");
            
            // handle new completion handler
            _fetchCompletion = completionHandler;
            
            return;
        }
        
        BOOL checkResult = [self checkAutoUpdateConditions];
        
        //Entry point for updating of the filters
        _fetchCompletion = completionHandler;
        
        [_antibannerController onReady:^(id<AESAntibannerProtocol> _Nonnull antibanner) {
            
            [antibanner repairUpdateStateWithCompletionBlock:^{
                
                if (antibanner.updatesRightNow) {
                    DDLogInfo(@"(AppDelegate) Update process did not start because it is performed right now.");
                    return;
                }
                
                if (!checkResult) {
                    DDLogInfo(@"(AppDelegate - Background Fetch) Cancel fetch. App settings permit updates only over WiFi.");
                    self.antibanerUpdateResult = UIBackgroundFetchResultNoData;
                }
                else {
                    self.antibanerUpdateResult = AEUpdateStarted;
                }
                
                if (!(checkResult && [self invalidateAntibanner:NO interactive:NO])){
                    
                    [self antibanerUpdateFinished:AEUpdateFailed];
                }
            }];
            
            [_purchaseService checkPremiumStatusChanged];
        }];
        
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (!_dnsFiltersService.filtersAreUpdating && now - lastCheckTime > DNS_FILTERS_CHECK_LIMIT && checkResult && _configuration.proStatus && checkResult){
            lastCheckTime = now;
            [_dnsFiltersService updateFiltersWithNetworking:_networking callback:nil];
            DDLogInfo(@"(AppDelegate - Background Fetch) Dns filters were updated");
        }
    }
}

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(nonnull NSString *)identifier completionHandler:(nonnull void (^)(void))completionHandler {

    DDLogInfo(@"(AppDelegate) application handleEventsForBackgroundURLSession.");

    if ([identifier isEqualToString:AE_FILTER_UPDATES_ID]) {
        
        [_antibannerController onReady:^(id<AESAntibannerProtocol> _Nonnull antibanner) {
            _downloadCompletion = completionHandler;
            [antibanner repairUpdateStateForBackground];
        }];
    }
    else{
        DDLogError(@"(AppDelegate) Uncknown background session id: %@", identifier);
        completionHandler();
    }
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options{
    
    DDLogError(@"(AppDelegate) application Open URL.");
    
    _activateWithOpenUrl = YES;
    
    return [helper application:app open:url options:options];
}

/////////////////////////////////////////////////////////////////////
#pragma mark Public Methods
/////////////////////////////////////////////////////////////////////

- (BOOL)invalidateAntibanner:(BOOL)fromUI interactive:(BOOL)interactive {
    
    @synchronized(self) {
        
        // Begin update process (Downloading step)
        
        NSDate *lastCheck = [_resources.sharedDefaults objectForKey:AEDefaultsCheckFiltersLastDate];
        if (fromUI || !lastCheck ||
            ([lastCheck timeIntervalSinceNow] * -1) >=
            AS_CHECK_FILTERS_UPDATES_PERIOD) {
            
            if (fromUI) {
                DDLogInfo(@"(AppDelegate) Update process started from UI.");
            }
            else{
                DDLogInfo(@"(AppDelegate) Update process started by timer.");
            }
            
            __block BOOL result = NO;
            
            [_antibanner beginTransaction];
            DDLogInfo(@"(AppDelegate) Begin of the Update Transaction from - invalidateAntibanner.");
            
            result = [_antibanner startUpdatingForced:fromUI interactive:interactive];
            
            if (! result) {
                DDLogInfo(@"(AppDelegate) Update process did not start because [antibanner startUpdatingForced] return NO.");
                [_antibanner rollbackTransaction];
                DDLogInfo(@"(AppDelegate) Rollback of the Update Transaction from ASAntibannerDidntStartUpdateNotification.");
            }
            
            return result;
        }
        
        DDLogInfo(@"(AppDelegate) Update process NOT started by timer. Time period from previous update too small.");
        
        
        return NO;
    }
}

- (void)resetAllSettings {
    [helper resetAllSettings];
}

/////////////////////////////////////////////////////////////////////
#pragma mark Notifications observers
/////////////////////////////////////////////////////////////////////

- (void)antibannerNotify:(NSNotification *)notification {
    
    // Update filter rule
    if ([notification.name isEqualToString:ASAntibannerUpdateFilterRulesNotification]){
        
        BOOL background = (_fetchCompletion || _downloadCompletion);
        [_contentBlockerService reloadJsonsWithBackgroundUpdate:background completion:^(NSError *error) {
            
            if (error) {
                [_antibanner rollbackTransaction];
                DDLogInfo(@"(AppDelegate) Rollback of the Update Transaction from ASAntibannerUpdateFilterRulesNotification.");
                
                [self updateFailuredNotify];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    UINavigationController* nav = [self getNavigationController];
                    if (nav.topViewController && [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground) {
                            
                            [ACSSystemUtils showSimpleAlertForController:nav.topViewController withTitle: ACLocalizedString(@"common_error_title", @"(AEUISubscriptionController) Alert title. When converting rules process finished in foreground updating.") message:ACLocalizedString(@"load_to_safari_error", @"(AppDegelate) Alert message. When converting rules process finished in foreground updating.")];
                        
                    }
                });
            }
            else{
                
                // Success antibanner updated from backend
                
                [_resources.sharedDefaults setObject:[NSDate date] forKey:AEDefaultsCheckFiltersLastDate];
                [_antibanner endTransaction];
                DDLogInfo(@"(AppDelegate) End of the Update Transaction from ASAntibannerUpdateFilterRulesNotification.");
                
                [self updateFinishedNotify];
            }
        }];
    }
    // Update started
    else if ([notification.name
              isEqualToString:ASAntibannerStartedUpdateNotification]) {
        
        // turn on network activity indicator
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        [self updateStartedNotify];
    }
    // Update did not start
    else if ([notification.name
              isEqualToString:ASAntibannerDidntStartUpdateNotification]) {
        
        if ([_antibanner inTransaction]) {
            
            [_antibanner rollbackTransaction];
            DDLogInfo(@"(AppDelegate) Rollback of the Update Transaction from ASAntibannerDidntStartUpdateNotification.");
        }
        
        // Special update case.
        [self antibanerUpdateFinished:AEUpdateFailed];
    }
    // Update performed
    else if ([notification.name
              isEqualToString:ASAntibannerFinishedUpdateNotification]) {
        
        _updatedFilters = [notification userInfo][ASAntibannerUpdatedFiltersKey];
        
        [_contentBlockerService reloadJsonsWithBackgroundUpdate:YES completion:^(NSError * _Nullable error) {
            
            if ([_antibanner inTransaction]) {
                // Success antibanner updated from backend
                [_resources.sharedDefaults setObject:[NSDate date] forKey:AEDefaultsCheckFiltersLastDate];
                [_antibanner endTransaction];
                DDLogInfo(@"(AppDelegate) End of the Update Transaction from ASAntibannerFinishedUpdateNotification.");
                
                [self updateFinishedNotify];
            }
            
            
            // Special update case (in background).
            [self antibanerUpdateFinished:AEUpdateNewData];
        }];
        
        // turn off network activity indicator
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
    // Update failed
    else if ([notification.name
              isEqualToString:ASAntibannerFailuredUpdateNotification]) {
        
        if ([_antibanner inTransaction]) {
            
            [_antibanner rollbackTransaction];
            DDLogInfo(@"(AppDelegate) Rollback of the Update Transaction from ASAntibannerFailuredUpdateNotification.");
        }
        
        [self updateFailuredNotify];
        
        // Special update case.
        [self antibanerUpdateFinished:AEUpdateFailed];
        
        // turn off network activity indicator
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
    else if ([notification.name
              isEqualToString:ASAntibannerUpdatePartCompletedNotification]){
        
        DDLogInfo(@"(AppDelegate) Antibanner update PART notification.");
        [self antibanerUpdateFinished:AEUpdateNewData];
    }
}

/////////////////////////////////////////////////////////////////////
#pragma mark Update Manager methods (private)
/////////////////////////////////////////////////////////////////////

- (void)updateStartedNotify{
    
    [ACSSystemUtils callOnMainQueue:^{
        
        DDLogDebug(@"(AppDelegate) Started update process.");
        [[NSNotificationCenter defaultCenter] postNotificationName:AppDelegateStartedUpdateNotification object:self];
    }];
}

- (void)updateFailuredNotify{
    
    
    [ACSSystemUtils callOnMainQueue:^{
        
        DDLogDebug(@"(AppDelegate) Failured update process.");
        [[NSNotificationCenter defaultCenter] postNotificationName:AppDelegateFailuredUpdateNotification object:self];
        
    }];
    
}

- (void)updateFinishedNotify{
    
    [ACSSystemUtils callOnMainQueue:^{
        
        DDLogDebug(@"(AppDelegate) Finished update process.");
        NSArray *metas = @[];
        
        if (_updatedFilters) {
            metas = _updatedFilters;
            _updatedFilters = nil;
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AppDelegateFinishedUpdateNotification object:self userInfo:@{AppDelegateUpdatedFiltersKey: metas}];
    }];
}

/**
 helper method for logs
 */
- (NSString*) resultDescription:(AEUpdateResult)result {
    NSArray<NSString*> *names = @[@"AEUpdateNotStarted",
                                  @"AEUpdateStarted",
                                  @"AEUpdateNewData",
                                  @"AEUpdateFailed",
                                  @"AEUpdateNoData"];
    
    return names[result];
}

- (void)antibanerUpdateFinished:(AEUpdateResult)result {
    DDLogDebug(@"(AppDelegate) antibanerUpdateFinished with result: %@", [self resultDescription:result]);
    self.antibanerUpdateResult = result;
    [self updateFinished];
}

- (void)blockingSubscriptionsUpdateFinished:(AEUpdateResult)result {
    DDLogDebug(@"(AppDelegate) blockingSubscriptionsUpdateFinished with result: %@", [self resultDescription:result]);
    self.blockingSubscriptionsUpdateResult = result;
    [self updateFinished];
}

- (void)updateFinished {
    
    DDLogDebug(@"(AppDelegate) updateFinished");
    
    if(self.antibanerUpdateResult == AEUpdateStarted || self.blockingSubscriptionsUpdateResult == AEUpdateStarted)
        return;
    
    UIBackgroundFetchResult result;
    
    if(self.antibanerUpdateResult == AEUpdateNewData || self.blockingSubscriptionsUpdateResult == AEUpdateNewData)
        result = UIBackgroundFetchResultNewData;
    else if(self.antibanerUpdateResult == AEUpdateNoData && self.blockingSubscriptionsUpdateResult == AEUpdateNoData)
        result = UIBackgroundFetchResultNoData;
    else
        result = UIBackgroundFetchResultFailed;
    
    [self callCompletionHandler:result];
}

- (void)callCompletionHandler:(UIBackgroundFetchResult)result{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if (_fetchCompletion) {
            NSArray *resultName = @[
                                    @"NewData",
                                    @"NoData",
                                    @"Failed"];

            DDLogInfo(@"(AppDelegate - Background Fetch) Call fetch Completion. With result: %@", resultName[result]);
            _fetchCompletion(result);
            _fetchCompletion = nil;
        }
        else if (_downloadCompletion){
            
            DDLogInfo(@"(AppDelegate - Background update downloads) Call Completion.");
            _downloadCompletion();
            _downloadCompletion = nil;
        }
        
    });
}

/////////////////////////////////////////////////////////////////////
#pragma mark Helpper Methods (private)
/////////////////////////////////////////////////////////////////////

- (BOOL)checkAutoUpdateConditions {

    BOOL result = YES;
    
    NSNumber* wifiOnlyObject = [_resources.sharedDefaults objectForKey:AEDefaultsWifiOnlyUpdates];
    BOOL wifiOnly = wifiOnlyObject ? wifiOnlyObject.boolValue : YES;
    
    if (wifiOnly) {
        
        Reachability *reach = [Reachability reachabilityForInternetConnection];
        
        result = [reach isReachableViaWiFi];
        
        if (! result) {
            DDLogInfo(@"(AppDelegate - checkAutoUpdateConditions) App settings permit updates only over WiFi.");
        }
    }
    
    return result;
}

- (UINavigationController*) getNavigationController {
    
    UINavigationController *nav = (UINavigationController *)self.window.rootViewController;
    
    if(![nav isKindOfClass:[UINavigationController class]]) {
        return nil;
    }
    
    return nav;
}

-(void)setAppInterfaceStyle {
    ConfigurationService *configuration = [ServiceLocator.shared getSetviceWithTypeName:@"ConfigurationService"];
    if (@available(iOS 13.0, *)) {
        switch (self.window.traitCollection.userInterfaceStyle) {
            case UIUserInterfaceStyleDark:
                configuration.systemAppearenceIsDark = YES;
                break;
        
            default:
                configuration.systemAppearenceIsDark = NO;
                break;
        }
    } else {
        configuration.systemAppearenceIsDark = NO;
    }

}

- (void)showAlertNotification:(NSNotification *)notification {
    NSString *body = notification.userInfo[UserNotificationService.notificationBody];
    NSString *title = notification.userInfo[UserNotificationService.notificationTitle];
    ASSIGN_WEAK(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        ASSIGN_STRONG(self);
        UINavigationController *nav = [USE_STRONG(self) getNavigationController];
        UIViewController *vc = [nav topViewController];
        
        [ACSSystemUtils showSimpleAlertForController:vc withTitle:title message:body];
    });
}

@end
