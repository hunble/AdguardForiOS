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


#import "APVPNManager.h"
#import <NetworkExtension/NetworkExtension.h>
#import "ACommons/ACLang.h"
#import "ACommons/ACSystem.h"
#import "AppDelegate.h"
#import "ACommons/ACNetwork.h"
#import "ASDFilterObjects.h"
#import "AESAntibanner.h"
#import "Adguard-Swift.h"
#import "APCommonSharedResources.h"

#define VPN_NAME                            @" VPN"
#define MAX_COUNT_OF_REMOTE_DNS_SERVERS     20
#define NOTIFICATION_DELAY                  1

NSString *APVpnChangedNotification = @"APVpnChangedNotification";

/////////////////////////////////////////////////////////////////////
#pragma mark - APVPNManager

@implementation APVPNManager{
    
    dispatch_queue_t workingQueue;
    NSOperationQueue *_notificationQueue;
    
    ACLExecuteBlockDelayed *_delayedSendNotify;
    
    NETunnelProviderManager *_manager;
    NSMutableArray *_observers;
    
    BOOL        _enabled;
    
    BOOL         _busy;
    NSLock      *_busyLock;
    NSNumber    *_delayedSetEnabled;
    
    DnsServerInfo *_activeDnsServer;
    DnsServerInfo *_delayedSetActiveDnsServer;
    
    APVpnManagerTunnelMode _tunnelMode;
    NSNumber          *_delayedSetTunnelMode;
    
    NSNumber          *_delayedRestartByReachability;
    BOOL              _delayedRestartTunnel;
    NSNumber          *_delayedFilteringWifiDataEnabled;
    NSNumber          *_delayedFilteringMobileDataEnabled;
    
    NSError     *_standartError;
    
    BOOL _restartByReachability;
    BOOL _filteringWifiDataEnabled;
    BOOL _filteringMobileDataEnabled;
    
    NSMutableArray <DnsProviderInfo *> *_customDnsProviders;
    
    DnsProvidersService * _providersService;
    
    AESharedResources *_resources;
    ConfigurationService *_configuration;
    NEVPNStatus _lastVpnStatus;
}

@synthesize connectionStatus = _connectionStatus;
@synthesize lastError = _lastError;
@synthesize delayedTurn = _delayedTurn;
@synthesize managerWasLoaded = _managerWasLoaded;

/////////////////////////////////////////////////////////////////////
#pragma mark Initialize and class properties

+ (void)initialize {
    // migration:
    // in app version 3.1.4 and below we mistakenly used the name Adguard.DnsProviderInfo with namespace
    // now we use DnsProviderInfo
    [NSKeyedUnarchiver setClass:DnsProviderInfo.class forClassName:@"Adguard.DnsProviderInfo"];
}

- (id)initWithResources: (nonnull AESharedResources*) resources
          configuration: (ConfigurationService *) configuration {
    
    self = [super init];
    if (self) {
        
        _managerWasLoaded = NO;
        _resources = resources;
        _configuration = configuration;
        workingQueue = dispatch_queue_create("APVPNManager", DISPATCH_QUEUE_SERIAL);
        _notificationQueue = [NSOperationQueue new];
        _notificationQueue.underlyingQueue = workingQueue;
        _notificationQueue.name = @"APVPNManager notification";
        _lastVpnStatus = -1;
        
        [_configuration addObserver:self forKeyPath:@"proStatus" options:NSKeyValueObservingOptionNew context:nil];
        
        ASSIGN_WEAK(self);
        // set delayed notify
        _delayedSendNotify = [[ACLExecuteBlockDelayed alloc]
                              initWithTimeout:NOTIFICATION_DELAY
                              leeway:NOTIFICATION_DELAY
                              queue:workingQueue block:^{
                                ASSIGN_STRONG(self);
            
                                  dispatch_async(dispatch_get_main_queue(), ^{
                                      
                                      if (USE_STRONG(self).lastError) {
                                          DDLogInfo(@"(APVPNManager) Notify others that vpn connection status changed with error: %@", self.lastError.localizedDescription);
                                      }
                                      else {
                                          DDLogInfo(@"(APVPNManager) Notify others that vpn connection status changed.");
                                      }
                                      [[NSNotificationCenter defaultCenter] postNotificationName:APVpnChangedNotification object:self];
                                      
                                      // Reset last ERROR!!!
                                      USE_STRONG(self)->_lastError = nil;
                                  });
                                  
        }];
        //------------------
        
        _busy = NO;
        _busyLock = [NSLock new];

        _standartError = [NSError
            errorWithDomain:APVpnManagerErrorDomain
                       code:APVPN_MANAGER_ERROR_STANDART
                   userInfo:@{
                       NSLocalizedDescriptionKey : ACLocalizedString(
                           @"support_vpn_configuration_problem", nil)
                   }];

        [self initDefinitions];

        [self attachToNotifications];
        
        _connectionStatus = APVpnConnectionStatusDisconnecting;
        _enabled = NO;
        
        _providersService = [DnsProvidersService new];
        
        // don't restart by default
        _restartByReachability = NO;
        
        _filteringMobileDataEnabled = YES;
        _filteringWifiDataEnabled = YES;
        
        [self loadConfiguration];
    }
    
    return self;
}

- (void)dealloc{
    
    for (id observer in _observers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    
    [_configuration removeObserver:self forKeyPath:@"proStatus"];
}

/////////////////////////////////////////////////////////////////////
#pragma mark Properties and public methods

- (BOOL)enabled {
    return _enabled;
}
- (void)setEnabled:(BOOL)enabled{
    
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        
        _delayedSetEnabled = @(enabled);
    }
    else{
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if(USE_STRONG(self)->_busy) {
                
                USE_STRONG(self)->_delayedSetEnabled = @(USE_STRONG(self).enabled);
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetEnabled:enabled force:NO];
            }
        });
    }
    
    [_busyLock unlock];
}

- (void)setActiveDnsServer:(DnsServerInfo *)activeDnsServer{
    
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        
        _delayedSetActiveDnsServer = activeDnsServer;
    } else {
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if (USE_STRONG(self)->_busy) {
                
                USE_STRONG(self)->_delayedSetActiveDnsServer = activeDnsServer;
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetRemoteServer:activeDnsServer];
            }
        });
    }
    
    [_busyLock unlock];
}

- (NSArray<DnsProviderInfo *> *)providers {
    return [_providersService.providers arrayByAddingObjectsFromArray:_customDnsProviders];
}

- (DnsProviderInfo *)activeDnsProvider {
    if (!self.activeDnsServer)
        return nil;
    
    for (DnsProviderInfo* provider in _providersService.providers) {
        for(DnsServerInfo* server in provider.servers) {
            if ([server.serverId isEqualToString: self.activeDnsServer.serverId]) {
                return provider;
            }
        }
    }
    
    return nil;
}

- (BOOL)isActiveProvider:(DnsProviderInfo *)provider {
    if (!self.activeDnsServer)
        return NO;
    
    for(DnsServerInfo* server in provider.servers) {
        if ([server.serverId isEqualToString: self.activeDnsServer.serverId]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isCustomProvider:(DnsProviderInfo *)provider {
    for (DnsProviderInfo* customProvider in _customDnsProviders) {
        if ([provider.servers.firstObject.serverId isEqual: customProvider.servers.firstObject.serverId]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL) isCustomServer:(DnsServerInfo *) server {
    for (DnsProviderInfo* provider in _customDnsProviders) {
        for (DnsServerInfo* customServer in provider.servers) {
            if ([customServer.serverId isEqual: server.serverId]) {
                return YES;
            }
        }
    }
    
    return NO;
}

- (BOOL) isCustomServerActive {
    return [self isCustomServer:_activeDnsServer];
}

- (DnsServerInfo *)activeDnsServer {
    return _activeDnsServer;
}

- (void)setTunnelMode:(APVpnManagerTunnelMode)tunnelMode {
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        
        _delayedSetTunnelMode = @(tunnelMode);
    } else {
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if (USE_STRONG(self)->_busy) {
                
                USE_STRONG(self)->_delayedSetTunnelMode = @(tunnelMode);
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetTunnelMode:tunnelMode];
            }
        });
    }
    
    [_busyLock unlock];
}

- (BOOL)restartByReachability {
    return _restartByReachability;
}

- (BOOL)filteringWifiDataEnabled {
    return _filteringWifiDataEnabled;
}

- (BOOL)filteringMobileDataEnabled {
    return _filteringMobileDataEnabled;
}


- (void)setRestartByReachability:(BOOL)restartByReachability {
    
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        
        _delayedRestartByReachability = @(restartByReachability);
    } else {
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if (USE_STRONG(self)->_busy) {
                
                USE_STRONG(self)->_delayedRestartByReachability = @(restartByReachability);
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetRestartByReachability:restartByReachability];
            }
        });
    }
    
     [_busyLock unlock];
}

- (void)setFilteringWifiDataEnabled:(BOOL)filteringWifiDataEnabled {
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        _delayedFilteringWifiDataEnabled = @(filteringWifiDataEnabled);
    } else {
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if (USE_STRONG(self)->_busy) {
                USE_STRONG(self)->_delayedFilteringWifiDataEnabled = @(filteringWifiDataEnabled);
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetFilteringWifiDataEnabled:filteringWifiDataEnabled];
            }
        });
    }
    
     [_busyLock unlock];
}

- (void)setFilteringMobileDataEnabled:(BOOL)filteringMobileDataEnabled {
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        _delayedFilteringMobileDataEnabled = @(filteringMobileDataEnabled);
    } else {
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if (USE_STRONG(self)->_busy) {
                USE_STRONG(self)->_delayedFilteringMobileDataEnabled = @(filteringMobileDataEnabled);
            } else {
                ASSIGN_STRONG(self);
                [USE_STRONG(self) internalSetFilteringMobileDataEnabled:filteringMobileDataEnabled];
            }
        });
    }
    
     [_busyLock unlock];
}

- (APVpnManagerTunnelMode)tunnelMode {
    return _tunnelMode;
}

- (BOOL)addRemoteDnsServer:(NSString *)name upstreams:(NSArray<NSString*>*) upstreams {
    
    DnsProviderInfo* provider = [_providersService createProviderWithName:name upstreams:upstreams];
    
    [self addCustomProvider: provider];
    
    [self setActiveDnsServer:provider.servers.firstObject];
    
    return YES;
}

- (BOOL)deleteCustomDnsProvider:(DnsProviderInfo *)provider {
    
    __block BOOL result;
    
    ASSIGN_WEAK(self);
    dispatch_sync(workingQueue, ^{
        ASSIGN_STRONG(self);
        
        if ([USE_STRONG(self) isActiveProvider:provider]) {
            USE_STRONG(self).activeDnsServer = nil;
        }
        
        // search provider by server id.
        DnsProviderInfo* foundProvider = nil;
        for (DnsProviderInfo* customProvider in _customDnsProviders) {
            // Each custom provider has only one server
            if ([customProvider.servers.firstObject.serverId isEqualToString:provider.servers.firstObject.serverId]) {
                foundProvider = customProvider;
                break;
            }
        }
        
        if (!foundProvider) {
            DDLogError(@"(APVPNManager) Error - can not delete custom dns provider with name: %@, upsrteams: %@", provider.name, provider.servers.firstObject.upstreams);
            result = NO;
            return;
        }
        
        [USE_STRONG(self) willChangeValueForKey:@"providers"];
        [_customDnsProviders removeObject:foundProvider];
        [USE_STRONG(self) didChangeValueForKey:@"providers"];
        
        [USE_STRONG(self) saveCustomDnsProviders];
        result = YES;
    });
    
    return YES;
}

- (BOOL)resetCustomDnsProvider:(DnsProviderInfo *)provider {
    
    __block BOOL result;
    
    dispatch_sync(workingQueue, ^{
       
        // search provider by server id.
        DnsProviderInfo* foundProvider = nil;
        for (DnsProviderInfo* customProvider in _customDnsProviders) {
            // Each custom provider has only one server
            if ([customProvider.servers.firstObject.serverId isEqualToString:provider.servers.firstObject.serverId]) {
                foundProvider = customProvider;
                break;
            }
        }
        
        if (!foundProvider) {
            DDLogError(@"(APVPNManager) Error - can not edit custom dns provider with name: %@, upsrteams: %@", provider.name, provider.servers.firstObject.upstreams);
            result = NO;
            return;
        }
        
        [self willChangeValueForKey:@"providers"];
        foundProvider.name = provider.name;
        foundProvider.servers.firstObject.upstreams = provider.servers.firstObject.upstreams;
        [self didChangeValueForKey:@"providers"];
        
        // update active server if needed
        if ([self isActiveProvider:provider]) {
            self.activeDnsServer =  provider.servers.firstObject;
        }
        
        [self saveCustomDnsProviders];
        result = YES;
    });
    
    return result;
}

- (void)restartTunnel {
    _lastError = nil;
    
    [_busyLock lock];
    
    if (_busy) {
        
        _delayedSetEnabled = @(YES);
    }
    else{
        ASSIGN_WEAK(self);
        dispatch_async(workingQueue, ^{
            ASSIGN_STRONG(self);
            if(USE_STRONG(self)->_busy) {
                USE_STRONG(self)->_delayedRestartTunnel = YES;
            } else {
                [self internalRestartTunnel];
            }
        });
    }
    
    [_busyLock unlock];
}

- (void) internalRestartTunnel {
    ASSIGN_WEAK(self);
    dispatch_async(workingQueue, ^{
        ASSIGN_STRONG(self);
        USE_STRONG(self)->_delayedRestartTunnel = NO;
        USE_STRONG(self)->_delayedSetEnabled = @(YES);
        [USE_STRONG(self) internalSetEnabled:NO force:YES];
    });
}

- (void) addCustomProvider: (DnsProviderInfo*) provider {
    
    dispatch_sync(workingQueue, ^{
        
        [self willChangeValueForKey:@"providers"];
        [_customDnsProviders addObject:provider];
        [self didChangeValueForKey:@"providers"];
        
        [self saveCustomDnsProviders];
        
    });
}

- (BOOL)vpnInstalled {
    return _manager != nil;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Key Value observing

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    
    if ([keyPath isEqualToString:@"proStatus"] && !_configuration.proStatus) {
        [self removeVpnConfiguration];
    }
}


/////////////////////////////////////////////////////////////////////
#pragma mark Helper Methods (Private)

//must be called on workingQueue
- (void)internalSetEnabled:(BOOL)enabled force:(BOOL)force{
    
    if (force || (enabled != _enabled)) {
       
        [self updateConfigurationForRemoteServer:_activeDnsServer tunnelMode:_tunnelMode restartByReachability:_restartByReachability enabled:enabled filteringMobileDataEnabled:_filteringMobileDataEnabled filteringWifiDataEnabled:_filteringWifiDataEnabled];
        
        // If do not completely stop the tunnel in full mode, then other VPNs can not start
        if(!enabled && _tunnelMode == APVpnManagerTunnelModeFull) {
            [(NETunnelProviderSession *)_manager.connection stopTunnel];
        }

    }
}

//must be called on workingQueue
- (void)internalSetRemoteServer:(DnsServerInfo *)server{
    
    if (_enabled) {
        _delayedSetEnabled = @(_enabled);
    }
    [self updateConfigurationForRemoteServer:server tunnelMode:_tunnelMode restartByReachability:_restartByReachability enabled:NO filteringMobileDataEnabled:_filteringMobileDataEnabled filteringWifiDataEnabled:_filteringWifiDataEnabled];
}

//must be called on workingQueue
- (void)internalSetTunnelMode:(APVpnManagerTunnelMode)tunnelMode {
    if(tunnelMode != _tunnelMode) {
        
        if (_enabled) {
            _delayedSetEnabled = @(_enabled);
        }
        [self updateConfigurationForRemoteServer:_activeDnsServer tunnelMode:tunnelMode restartByReachability:_restartByReachability enabled:NO filteringMobileDataEnabled:_filteringMobileDataEnabled filteringWifiDataEnabled:_filteringWifiDataEnabled];
    }
}

//must be called on workingQueue
- (void)internalSetRestartByReachability:(BOOL)restart {
    
    if(restart != _restartByReachability) {
        
        if (_enabled) {
            _delayedSetEnabled = @(_enabled);
        }
        [self updateConfigurationForRemoteServer:_activeDnsServer tunnelMode:_tunnelMode restartByReachability:restart enabled:NO filteringMobileDataEnabled:_filteringMobileDataEnabled filteringWifiDataEnabled:_filteringWifiDataEnabled];
    }
}

//must be called on workingQueue
- (void)internalSetFilteringWifiDataEnabled:(BOOL)enabled {
    
    if (enabled != _filteringWifiDataEnabled) {
        if (_enabled) {
            _delayedSetEnabled = @(_enabled);
        }
        [self updateConfigurationForRemoteServer:_activeDnsServer tunnelMode:_tunnelMode restartByReachability:_restartByReachability enabled:NO filteringMobileDataEnabled:_filteringMobileDataEnabled filteringWifiDataEnabled:enabled];
    }
}

//must be called on workingQueue
- (void)internalSetFilteringMobileDataEnabled:(BOOL)enabled {
    
    if (enabled != _filteringMobileDataEnabled) {
        if (_enabled) {
            _delayedSetEnabled = @(_enabled);
        }
        [self updateConfigurationForRemoteServer:_activeDnsServer tunnelMode:_tunnelMode restartByReachability:_restartByReachability enabled:NO filteringMobileDataEnabled:enabled filteringWifiDataEnabled:_filteringWifiDataEnabled];
    }
}

- (void)loadConfiguration{

    [_busyLock lock];
    _busy = YES;
    [_busyLock unlock];
    
    ASSIGN_WEAK(self);
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable error) {
        ASSIGN_STRONG(self);
        if (error){
            DDLogError(@"(APVPNManager) Error loading vpn configuration: %@, %ld, %@", error.domain, error.code, error.localizedDescription);
            USE_STRONG(self)->_lastError = USE_STRONG(self)->_standartError;
        }
        else {
            
            if (managers.count) {
                //Checks that loaded configuration is related to tunnel bundle ID.
                //If no, removes all old configurations.
                if (managers.count > 1 || ! [((NETunnelProviderProtocol *)managers.firstObject.protocolConfiguration).providerBundleIdentifier isEqualToString:AP_TUNNEL_ID]) {
                    
                    DDLogError(@"(APVPNManager) Error. there are %lu managers in system. Remove all", managers.count);
                    for (NETunnelProviderManager *item in managers) {
                        [item removeFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                            if(error) {
                                DDLogError(@"(APVPNManager) Error. Manager removing failed with error: %@", error.localizedDescription);
                            }
                            else {
                                DDLogInfo(@"(APVPNManager). Manager successfully removed");
                            }
                        }];
                    }
                    
                    USE_STRONG(self)->_manager = nil;
                }
                else {
                    
                    USE_STRONG(self)->_manager = managers[0];
                }
            } else {
                USE_STRONG(self)->_manager = nil;
            }
        }

        [USE_STRONG(self)->_busyLock lock];
        USE_STRONG(self)->_busy = NO;
        [USE_STRONG(self)->_busyLock unlock];
        
        ASSIGN_WEAK(self);
        dispatch_sync(USE_STRONG(self)->workingQueue, ^{
            ASSIGN_STRONG(self);
            [USE_STRONG(self) setStatuses];
        });
        
        if (error) {
            DDLogInfo(@"(APVPNManager) Loading vpn conviguration failured: %@",
                      (self.activeDnsServer.name ?: @"None"));
        }
        else{
            DDLogInfo(@"(APVPNManager) Vpn configuration successfully loaded: %@",
                      (self.activeDnsServer.name ?: @"None"));
        }
        
        [self sendNotificationForced:YES];
        if (USE_STRONG(self)->_delayedTurn){
            USE_STRONG(self)->_delayedTurn();
        }
        self.managerWasLoaded = YES;
    }];
    
}

- (void)updateConfigurationForRemoteServer:(DnsServerInfo *)remoteServer tunnelMode:(APVpnManagerTunnelMode) tunnelMode restartByReachability:(BOOL)restartByReachability
    enabled:(BOOL)enabled
    filteringMobileDataEnabled:(BOOL)filteringMobileDataEnabled
    filteringWifiDataEnabled:(BOOL)filteringWifiDataEnabled {
    
    // do not update configuration for not premium users
    if (!_configuration.proStatus) {
        return;
    }

    [_busyLock lock];
    _busy = YES;
    [_busyLock unlock];
    
    NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)_manager.protocolConfiguration;
    NETunnelProviderManager *newManager;
    
    if (!protocol)
    {
        protocol = [NETunnelProviderProtocol new];
        protocol.providerBundleIdentifier =  AP_TUNNEL_ID;
    }
    
    NSData *remoteServerData = [NSKeyedArchiver archivedDataWithRootObject:remoteServer];
    protocol.serverAddress = remoteServer ? remoteServer.name : ACLocalizedString(@"default_dns_server_name", nil);
    
    protocol.providerConfiguration = @{
                                       APVpnManagerParameterRemoteDnsServer: remoteServerData,
                                       APVpnManagerParameterTunnelMode: @(tunnelMode),
                                       APVpnManagerRestartByReachability : @(restartByReachability),
                                       APVpnManagerFilteringMobileDataEnabled: @(filteringMobileDataEnabled),
                                       APVpnManagerFilteringWifiDataEnabled:@(filteringWifiDataEnabled)
                                       };
    
    if (_manager) {
        newManager = _manager;
    }
    else{
        newManager = [NETunnelProviderManager new];
        newManager.protocolConfiguration = protocol;
        
        // Configure onDemand
        NEOnDemandRuleConnect *rule = [NEOnDemandRuleConnect new];
        rule.interfaceTypeMatch = NEOnDemandRuleInterfaceTypeAny;
        newManager.onDemandRules = @[rule];
    }
    
    newManager.enabled = enabled;
    newManager.onDemandEnabled = enabled;
    newManager.localizedDescription = AE_PRODUCT_NAME VPN_NAME;
    
    ASSIGN_WEAK(self);
    [newManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
        ASSIGN_STRONG(self);
        if (error){
            
            DDLogError(@"(APVPNManager) Error updating vpn configuration: %@, %ld, %@", error.domain, error.code, error.localizedDescription);
            USE_STRONG(self)->_lastError = USE_STRONG(self)->_standartError;

            [USE_STRONG(self)->_busyLock lock];
            USE_STRONG(self)->_busy = NO;
            [USE_STRONG(self)->_busyLock unlock];
            
            dispatch_sync(USE_STRONG(self)->workingQueue, ^{
                
                [USE_STRONG(self) setStatuses];
            });
            
            DDLogInfo(@"(APVPNManager) Updating vpn conviguration failed: %@",
                      (USE_STRONG(self).activeDnsServer.name ?: @"None"));
            
            [USE_STRONG(self) loadConfiguration];
            [USE_STRONG(self) sendNotificationForced:NO];
            return;
        }
        
        DDLogInfo(@"(APVPNManager) Vpn configuration successfully updated: %@",
                  (USE_STRONG(self).activeDnsServer.name ?: @"None"));
        
        [USE_STRONG(self) loadConfiguration];
    }];
}

- (void)removeVpnConfiguration {
    
    [_busyLock lock];
    _busy = YES;
    [_busyLock unlock];
    
    ASSIGN_WEAK(self);
    
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable error) {
        ASSIGN_STRONG(self);
        if (error){
            
            DDLogError(@"(APVPNManager) removeVpnConfiguration - Error loading vpn configuration: %@, %ld, %@", error.domain, error.code, error.localizedDescription);
            USE_STRONG(self)->_lastError = USE_STRONG(self)->_standartError;
        }
        else {
            
            if (managers.count) {
                for (NETunnelProviderManager *item in managers) {
                    [item removeFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                        if(error) {
                            DDLogError(@"(APVPNManager) Error. Manager removing failed with error: %@", error.localizedDescription);
                        }
                        else {
                            DDLogInfo(@"(APVPNManager) Error. Manager successfully removed");
                        }
                    }];
                }
            }
        }
        
        USE_STRONG(self)->_manager = nil;
        USE_STRONG(self)->_enabled = NO;

        [USE_STRONG(self)->_busyLock lock];
        USE_STRONG(self)->_busy = NO;
        [USE_STRONG(self)->_busyLock unlock];
    }];
}

- (void)setStatuses{
    
    _enabled = NO;
    
    if (_manager) {
        
        NETunnelProviderProtocol * protocolConfiguration = (NETunnelProviderProtocol *)_manager.protocolConfiguration;
        NSData *remoteDnsServerData = protocolConfiguration.providerConfiguration[APVpnManagerParameterRemoteDnsServer];
        
        // Getting current settings from configuration.
        DnsServerInfo *remoteServer = [NSKeyedUnarchiver unarchiveObjectWithData:remoteDnsServerData];
        if (_activeDnsServer.serverId != remoteServer.serverId) {
            [self willChangeValueForKey:@"activeDnsServer"];
            _activeDnsServer = [NSKeyedUnarchiver unarchiveObjectWithData:remoteDnsServerData];
            [self didChangeValueForKey:@"activeDnsServer"];
        }
        
        _resources.activeDnsServer = _activeDnsServer;
        DDLogInfo(@"(APVPNManager) active dns server changed. New dns server is: %@", _activeDnsServer.name);
        
        [_resources.sharedDefaults setInteger: _tunnelMode forKey:AEDefaultsVPNTunnelMode];
        
        [self willChangeValueForKey:@"tunnelMode"];
        _tunnelMode = protocolConfiguration.providerConfiguration[APVpnManagerParameterTunnelMode] ?
        [protocolConfiguration.providerConfiguration[APVpnManagerParameterTunnelMode] unsignedIntValue] : APVpnManagerTunnelModeSplit;
        
        // update it async to prevent deadlocks on NETunnelProvider serial queue
        dispatch_async(dispatch_get_main_queue(), ^{
            [self didChangeValueForKey:@"tunnelMode"];
        });
        //-------------
        
        _restartByReachability = protocolConfiguration.providerConfiguration[APVpnManagerRestartByReachability] ?
        [protocolConfiguration.providerConfiguration[APVpnManagerRestartByReachability] boolValue] : NO; // NO by default
        
        _filteringMobileDataEnabled = protocolConfiguration.providerConfiguration[APVpnManagerFilteringMobileDataEnabled] ? [protocolConfiguration.providerConfiguration[APVpnManagerFilteringMobileDataEnabled] boolValue] : YES; // YES by default
        
        _filteringWifiDataEnabled = protocolConfiguration.providerConfiguration[APVpnManagerFilteringWifiDataEnabled] ? [protocolConfiguration.providerConfiguration[APVpnManagerFilteringWifiDataEnabled] boolValue] : YES; // YES by default
        
        // Save to user defaults
        [_resources.sharedDefaults setBool:_restartByReachability forKey:AEDefaultsRestartByReachability];
        [_resources.sharedDefaults setBool:_filteringMobileDataEnabled forKey:AEDefaultsFilterMobileEnabled];
        [_resources.sharedDefaults setBool:_filteringWifiDataEnabled forKey:AEDefaultsFilterWifiEnabled];
        
        NSString *connectionStatusReason = @"Unknown";
        
        if (_manager.enabled && _manager.onDemandEnabled) {
            
            _enabled = YES;

            switch (_manager.connection.status) {
                    
                case NEVPNStatusDisconnected:
                    _connectionStatus = APVpnConnectionStatusDisconnected;
                    connectionStatusReason = @"NEVPNStatusDisconnected The VPN is disconnected.";
                    break;
                    
                case NEVPNStatusReasserting:
                    _connectionStatus = APVpnConnectionStatusReconnecting;
                    connectionStatusReason = @"NEVPNStatusReasserting The VPN is reconnecting following loss of underlying network connectivity.";
                    break;
                    
                case NEVPNStatusConnecting:
                    _connectionStatus = APVpnConnectionStatusReconnecting;
                    connectionStatusReason = @"NEVPNStatusConnecting The VPN is connecting.";
                    break;
                    
                case NEVPNStatusDisconnecting:
                    _connectionStatus = APVpnConnectionStatusDisconnecting;
                    connectionStatusReason = @"NEVPNStatusDisconnecting The VPN is disconnecting.";
                    break;
                    
                case NEVPNStatusConnected:
                    _connectionStatus = APVpnConnectionStatusConnected;
                    connectionStatusReason = @"NEVPNStatusConnected The VPN is connected.";
                    break;
                    
                case NEVPNStatusInvalid:
                    connectionStatusReason = @"NEVPNStatusInvalid The VPN is not configured.";
                default:
                    _connectionStatus = APVpnConnectionStatusInvalid;
                    break;
            }
        }
        else{
            
            _connectionStatus = APVpnConnectionStatusDisabled;
        }
        
        DDLogInfo(@"(APVPNManager) Updated Status:\nmanager.enabled = %@\nmanager.onDemandEnabled = %@\nConnection Status: %@", _manager.enabled ? @"YES" : @"NO", _manager.onDemandEnabled ? @"YES" : @"NO", connectionStatusReason);
    }
    else{
        [self willChangeValueForKey:@"activeDnsServer"];
        _activeDnsServer = nil;
        [self didChangeValueForKey:@"activeDnsServer"];
        
        _connectionStatus = APVpnConnectionStatusDisabled;
        
        DDLogInfo(@"(APVPNManager) Updated Status:\nNo manager instance.");
        DDLogInfo(@"(APVPNManager) active dns server changed to default: %@", _activeDnsServer.name);
    }
    [_resources.sharedDefaults setBool:_enabled forKey:AEDefaultsVPNEnabled];
    // start delayed
    [self startDelayedOperationsIfNeedIt];
}

- (void)attachToNotifications{
    
    _observers = [NSMutableArray arrayWithCapacity:2];
    
    ASSIGN_WEAK(self);
    
    id observer = [[NSNotificationCenter defaultCenter]
                   addObserverForName:NEVPNConfigurationChangeNotification
                   object: nil
                   queue:_notificationQueue
                   usingBlock:^(NSNotification *_Nonnull note) {
                    
                    DDLogInfo(@"(APVPNManager) NEVPNConfigurationChangeNotification received");
                    
                    ASSIGN_STRONG(self);
                    // When VPN configuration is changed
                    [USE_STRONG(self)->_manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
                        ASSIGN_STRONG(self);
                        if(!error) {
                            DDLogInfo(@"(APVPNManager) Notify that vpn configuration changed.");
                            dispatch_sync(USE_STRONG(self)->workingQueue, ^{
                                [USE_STRONG(self) setStatuses];
                            });
                        } else {
                            DDLogError(@"(APVPNManager) Error loading vpn configuration: %@, %ld, %@", error.domain, error.code, error.localizedDescription);
                            USE_STRONG(self)->_lastError = USE_STRONG(self)->_standartError;
                        }
                    }];
                   }];
    
    [_observers addObject:observer];
    
    observer = [[NSNotificationCenter defaultCenter]
                   addObserverForName:NEVPNStatusDidChangeNotification
                object: nil
                   queue:_notificationQueue
                   usingBlock:^(NSNotification *_Nonnull note) {
                        
                        ASSIGN_STRONG(self);
                        DDLogInfo(@"(APVPNManager) NEVPNStatusDidChangeNotification received");
                        NEVPNConnection* connection = note.object;
                        if(connection != nil) {
                            // skip a lot of reccuring "connecting" and "disconnecting" status notifications
                            if (connection.status == USE_STRONG(self)->_lastVpnStatus) {
                                DDLogInfo(@"(APVPNManager) skip NEVPNStatusDidChangeNotification. Connection status = %ld", connection.status);
                                return;
                            }
                            else {
                                USE_STRONG(self)->_lastVpnStatus = connection.status;
                            }
                        }
                        
                        // When connection status is changed
                        [USE_STRONG(self)->_manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
                            ASSIGN_STRONG(self);
                            if(!error) {
                                DDLogInfo(@"(APVPNManager) Notify that vpn connection status changed.");
                                
                                dispatch_sync(USE_STRONG(self)->workingQueue, ^{
                                    ASSIGN_STRONG(self);
                                    [USE_STRONG(self) setStatuses];
                                    [USE_STRONG(self) loadConfiguration];
                                });
                            } else {
                                DDLogError(@"(APVPNManager) Error loading vpn configuration: %@, %ld, %@", error.domain, error.code, error.localizedDescription);
                                USE_STRONG(self)->_lastError = USE_STRONG(self)->_standartError;
                            }
                        }];
                   }];
    
    [_observers addObject:observer];
    
}

- (void)startDelayedOperationsIfNeedIt{
    
    [_busyLock lock];
    if (!_busy) {
        
        if (_lastError) {
            _delayedSetEnabled = nil;
            _delayedSetActiveDnsServer = nil;
            _delayedSetTunnelMode = nil;
            _delayedFilteringMobileDataEnabled = nil;
            _delayedFilteringWifiDataEnabled = nil;
            _delayedRestartByReachability = nil;
        }
        
        int localValue = 0;
        if (_delayedSetActiveDnsServer) {
            DnsServerInfo *server = _delayedSetActiveDnsServer;
            _delayedSetActiveDnsServer = nil;
            dispatch_async(workingQueue, ^{
                [self internalSetRemoteServer:server];
            });
        }
        else if (_delayedSetEnabled){
            
            localValue = [_delayedSetEnabled boolValue];
            _delayedSetEnabled = nil;
            dispatch_async(workingQueue, ^{
                [self internalSetEnabled:localValue force:NO];
            });
        }
        else if (_delayedSetTunnelMode) {
            
            APVpnManagerTunnelMode mode = [_delayedSetTunnelMode unsignedIntegerValue];
            _delayedSetTunnelMode = nil;
            dispatch_async(workingQueue, ^{
                [self internalSetTunnelMode:mode];
            });
        }
        else if (_delayedRestartTunnel) {
            dispatch_async(workingQueue, ^{
                [self restartTunnel];
            });
        }
        else if (_delayedFilteringMobileDataEnabled) {
            BOOL mobileEnabled = [_delayedFilteringMobileDataEnabled boolValue];
            _delayedFilteringMobileDataEnabled = nil;
            dispatch_async(workingQueue, ^{
                 [self internalSetFilteringMobileDataEnabled:mobileEnabled];
             });
        }
        else if (_delayedFilteringWifiDataEnabled) {
            BOOL wifiEnabled = [_delayedFilteringWifiDataEnabled boolValue];
            _delayedFilteringWifiDataEnabled = nil;
            dispatch_async(workingQueue, ^{
                 [self internalSetFilteringWifiDataEnabled:wifiEnabled];
             });
        }
        else if (_delayedRestartByReachability) {
            BOOL restartEnabled = [_delayedRestartByReachability boolValue];
            _delayedRestartByReachability = nil;
            dispatch_async(workingQueue, ^{
                 [self internalSetRestartByReachability:restartEnabled];
             });
        }
    }
    
    [_busyLock unlock];
}

- (void)initDefinitions{
    [self loadCustomDnsProviders];
}

- (void)sendNotificationForced:(BOOL)forced{
    
    if (forced) {
        [_delayedSendNotify executeNow];
    }
    else {
        [_delayedSendNotify executeOnceAfterCalm];
    }
}

- (void)saveCustomDnsProviders {
    
    NSData *dataForSave = [NSKeyedArchiver archivedDataWithRootObject:_customDnsProviders];
    
    if (dataForSave) {
        [_resources.sharedDefaults setObject:dataForSave forKey:APDefaultsCustomDnsProviders];
        [_resources.sharedDefaults synchronize];
    }
}

- (void)loadCustomDnsProviders {
    
    NSData *loadedData = [_resources.sharedDefaults objectForKey:APDefaultsCustomDnsProviders];
    
    if(loadedData) {
        _customDnsProviders = [NSKeyedUnarchiver unarchiveObjectWithData:loadedData];
    }
    
    if(!_customDnsProviders) {
        _customDnsProviders = [NSMutableArray new];
    }
}

@end

