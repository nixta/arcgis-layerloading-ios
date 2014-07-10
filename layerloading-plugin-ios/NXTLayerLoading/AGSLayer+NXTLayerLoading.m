//
//  AGSLayer+NXTLayerLoading.m
//  arcgis-layerloading-ios
//
//  Created by Nicholas Furness on 1/15/13.
//  Copyright (c) 2013 Esri. All rights reserved.
//

#import "AGSLayer+NXTLayerLoading.h"
#import <objc/runtime.h>

#define kLL_LayerIsTrackingKey @"NXTLLLayerIsTracking"
#define kLL_LayerWasInScaleKey @"NXTLLLayerWasInScale"

#define kFeatureLayerTrackingQueryOpKey    @"queryOperation"
#define kFeatureLayerTrackingConnectionKey @"connection"
#define kTiledLayerTrackingQueueCountKey   @"queue.operationCount"

NSString *const kNXTLLNotification_LayerLoading                     = @"NXTLLLayerLoading";
NSString *const kNXTLLNotification_LayerLoaded                      = @"NXTLLLayerLoaded";
NSString *const kNXTLLNotification_LayerNoLongerVisibleByScaleRange = @"NXTLLLayerNoLongerInScale";
NSString *const kNXTLLNotification_LayerNowVisibleByScaleRange      = @"NXTLLLayerNowInScale";
NSString *const kNXTLLNotification_LayerTrackingStartedForLayer     = @"NXTLLLayerTrackingOn";
NSString *const kNXTLLNotification_LayerTrackingStoppedForLayer     = @"NXTLLLayerTrackingOff";

@interface AGSLayer (NXTLayerLoading_Internal)
@property (nonatomic, assign, readwrite) BOOL nxtll_isTracking;
@property (nonatomic, assign, readwrite) BOOL nxtll_wasInScale;
@end

@implementation AGSLayer (NXTLayerLoading)
#pragma mark - Tracking Properties
-(BOOL)nxtll_isTracking
{
    NSNumber *temp = objc_getAssociatedObject(self, kLL_LayerIsTrackingKey);
    if (temp)
    {
        return temp.boolValue;
    }
    return NO;
}

-(void)setNxtll_isTracking:(BOOL)nxtll_isTracking
{
    NSNumber *temp = [NSNumber numberWithBool:nxtll_isTracking];
    
    objc_setAssociatedObject(self, kLL_LayerIsTrackingKey, temp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (nxtll_isTracking)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNXTLLNotification_LayerTrackingStartedForLayer object:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nxtll_mapZoomChanged:) name:AGSMapViewDidEndZoomingNotification object:self.mapView];
        [self nxtll_scaleVisibilityChanged];
    }
    else
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNXTLLNotification_LayerTrackingStoppedForLayer object:self];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AGSMapViewDidEndZoomingNotification object:self.mapView];
    }
}

-(BOOL)nxtll_wasInScale
{
    NSNumber *temp = objc_getAssociatedObject(self, kLL_LayerWasInScaleKey);
    if (temp)
    {
        return temp.boolValue;
    }
    return NO;
}

-(void)setNxtll_wasInScale:(BOOL)newValue
{
    NSNumber *temp = [NSNumber numberWithBool:newValue];
    
    objc_setAssociatedObject(self, kLL_LayerWasInScaleKey, temp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

-(void)nxtll_mapZoomChanged:(NSNotification *)notification
{
    [self nxtll_checkInScale];
}

-(void)nxtll_checkInScale
{
    if (self.nxtll_wasInScale != self.isInScale) {
        [self nxtll_scaleVisibilityChanged];
    }
}

#pragma mark - Tracking Control
-(void)nxtll_startTracking
{
    self.nxtll_wasInScale = NO;
    
    if ([self isKindOfClass:[AGSFeatureLayer class]])
    {
        // Feature Layer
        AGSFeatureLayer *fl = (AGSFeatureLayer *)self;
        
        [fl addObserver:self
             forKeyPath:kFeatureLayerTrackingQueryOpKey
                options:NSKeyValueObservingOptionNew + NSKeyValueObservingOptionInitial + NSKeyValueObservingOptionOld
                context:nil];
        
        self.nxtll_isTracking = YES;
    }
    else if ([self respondsToSelector:@selector(queue)])
    {
        // Tiled Layer
        [self addObserver:self
            forKeyPath:kTiledLayerTrackingQueueCountKey
               options:NSKeyValueObservingOptionNew + NSKeyValueObservingOptionInitial + NSKeyValueObservingOptionOld
               context:nil];

        self.nxtll_isTracking = YES;
    }
    else
    {
        // Not expecting to get here.
        NSLog(@"**** Cannot track loading on this kind of layer: %@", self);
        self.nxtll_isTracking = NO;
    }
}

-(void)nxtll_stopTracking
{
    if ([self isKindOfClass:[AGSFeatureLayer class]])
    {
        id qOp = [self performSelector:@selector(queryOperation)];
        
        if (qOp)
        {
            // Remove these lines and you'll get a KVO warning when the layer is removed.
            //
            // Shouldn't the KVO below handle removing this observer?
            // Probably, yes, but doubtless when this layer is removed then internally
            // it's nulling the iVar rather than nulling the property, and so bypassing KVO.
            //
            // Just a hunch.
            [qOp removeObserver:self forKeyPath:kFeatureLayerTrackingConnectionKey];
        }
        
        [self removeObserver:self forKeyPath:kFeatureLayerTrackingQueryOpKey];
    }
    else if ([self respondsToSelector:@selector(queue)])
    {
        [self removeObserver:self forKeyPath:kTiledLayerTrackingQueueCountKey];
    }
    else
    {
        // Not expecting to get here.
        NSLog(@"**** Cannot track loading on this kind of layer: %@", self);
    }
    
    self.nxtll_isTracking = NO;
}

#pragma mark - Tracking Logic
-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:kTiledLayerTrackingQueueCountKey])
    {
        // This is either an AGSDynamicLayer or an AGSTiledLayer
        NSInteger newCount = [(NSNumber *)[change objectForKey:NSKeyValueChangeNewKey] integerValue];
        if ([change objectForKey:NSKeyValueChangeOldKey] == nil)
        {
            // OldKey was nil: Layer just getting set up.
            if (newCount > 0)
            {
                NSLog(@"Unexpected start to layer load");
                [self nxtll_layerLoaded];
            }
        }
        else
        {
            // OldKey was not nil: Layer is changing its operation count...
            NSInteger oldCount = [(NSNumber *)[change objectForKey:NSKeyValueChangeOldKey] integerValue];
            
            if (oldCount == 0 && newCount > 0)
            {
                // Just started loading
                [self nxtll_layerLoading];
            }
            else if (oldCount > 0 && newCount == 0)
            {
                // Just finished loading
                [self nxtll_layerLoaded];
            }
        }
    }
    else if ([keyPath isEqualToString:kFeatureLayerTrackingQueryOpKey])
    {
        // The following is based off observation and experiment. It could be incomplete:
        //
        // In this case we have a feature layer and are inspecting its queryOperation
        // The queryOperation is nil unless the featurelayer is getting ready to ask
        // for more features. When it actually asks for more, it'll set it's connection
        // property to non-nil, so we'll watch for that.
        NSOperation *oldQueryOperation = [change objectForKey:NSKeyValueChangeOldKey];
        NSOperation *newQueryOperation = [change objectForKey:NSKeyValueChangeNewKey];
        if (oldQueryOperation != newQueryOperation)
        {
            if (oldQueryOperation != nil &&
                oldQueryOperation != (id)[NSNull null])
            {
                // The queryOperation is being nilled, so let's stop observing it's connection.
                [oldQueryOperation removeObserver:self forKeyPath:kFeatureLayerTrackingConnectionKey];
            }
            
            if (newQueryOperation != nil &&
                newQueryOperation != (id)[NSNull null])
            {
                // A new queryOperation exists, so let's *start* watching its connection.
                [newQueryOperation addObserver:self
                        forKeyPath:kFeatureLayerTrackingConnectionKey
                           options:NSKeyValueObservingOptionNew + NSKeyValueObservingOptionInitial + NSKeyValueObservingOptionOld
                           context:nil];
                // Note, this doesn't mean it's loading yet, just that it's getting ready to load...
            }
        }
    }
    else if ([keyPath isEqualToString:kFeatureLayerTrackingConnectionKey])
    {
        // This is the connection on the queryOperation subclass.
        NSURLConnection *oldConnection = [change objectForKey:NSKeyValueChangeOldKey];
        NSURLConnection *newConnection = [change objectForKey:NSKeyValueChangeNewKey];
        
        if (newConnection != nil &&
            newConnection != (id)[NSNull null])
        {
            // Went from Not Loading to Loading
            [self nxtll_layerLoading];
        }
        else
        {
            if (oldConnection &&
                oldConnection != (id)[NSNull null])
            {
                // Went from Loading to Not Loading (aka Loaded)
                [self nxtll_layerLoaded];
            }
        }
    }
}

#pragma mark - Notification Generation
-(void)nxtll_scaleVisibilityChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:self.isInScale?kNXTLLNotification_LayerNowVisibleByScaleRange:kNXTLLNotification_LayerNoLongerVisibleByScaleRange object:self];
        self.nxtll_wasInScale = self.isInScale;
    });
}

-(void)nxtll_layerLoading
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kNXTLLNotification_LayerLoading object:self];
    });
}

-(void)nxtll_layerLoaded
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kNXTLLNotification_LayerLoaded object:self];
    });
}
@end
