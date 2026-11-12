// Based on TouchBarFloor and TouchBarController (MIT).
// See Resources/TouchBarBrightness-LICENSE.txt for attribution and license.
#import "PowerTelemetrySupport.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <float.h>
#import <string.h>

// These objects are used only from TouchBarPower on the main actor.
static id dfr = nil;
static id core = nil;
static int displayID = -1;
static CFAbsoluteTime lastAttempt = -DBL_MAX;

static bool connectDisplay(void) {
    if (dfr && core && displayID >= 0) return true;
    if (CFAbsoluteTimeGetCurrent() - lastAttempt < 5) return false;
    lastAttempt = CFAbsoluteTimeGetCurrent();
    if (!dlopen("/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness", RTLD_LAZY)
        || !dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) return false;
    Class dfrClass = NSClassFromString(@"DFRBrightnessClient");
    Class coreClass = NSClassFromString(@"BrightnessSystemClient");
    if (!dfrClass || !coreClass) return false;
    if (!core) core = [[coreClass alloc] init];
    SEL initialize = NSSelectorFromString(@"initializeHID");
    SEL add = NSSelectorFromString(@"addDFRService:");
    SEL getID = NSSelectorFromString(@"getDFRDisplayID");
    id client = [[dfrClass alloc] init];
    IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFArrayRef services = system ? IOHIDEventSystemClientCopyServices(system) : NULL;
    if (services && [client respondsToSelector:initialize] && [client respondsToSelector:add]
        && [client respondsToSelector:getID]
        && ((BOOL (*)(id, SEL))objc_msgSend)(client, initialize)) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            BOOL match = product && [(__bridge id)product isEqual:@"TouchBarUserDevice"];
            if (product) CFRelease(product);
            if (!match) continue;
            BOOL added = ((BOOL (*)(id, SEL, IOHIDServiceClientRef))objc_msgSend)(client, add, service);
            int value = ((int (*)(id, SEL))objc_msgSend)(client, getID);
            if (added && value >= 0) { dfr = client; displayID = value; }
            break;
        }
    }
    if (services) CFRelease(services);
    if (system) CFRelease(system);
    return dfr && core && displayID >= 0;
}

static NSInteger displayState(void) {
    SEL get = NSSelectorFromString(@"copyPropertyForKey:");
    if (![dfr respondsToSelector:get]) return -1;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(dfr, get, @"DFRDisplayState");
    NSInteger state = [value isKindOfClass:NSNumber.class] ? [value integerValue] : -1;
    return state;
}

static double driverNits(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"), &iterator) != KERN_SUCCESS)
        return -1;
    double nits = -1;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        io_registry_entry_t parent = IO_OBJECT_NULL;
        char name[128] = {0};
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            IORegistryEntryGetName(parent, name);
            IOObjectRelease(parent);
        }
        bool match = strcmp(name, "backlight-dfr") == 0;
        if (match) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentNits"), kCFAllocatorDefault, 0);
            if (value && CFGetTypeID(value) == CFNumberGetTypeID())
                CFNumberGetValue(value, kCFNumberDoubleType, &nits);
            if (value) CFRelease(value);
        }
        IOObjectRelease(service);
        if (match) break;
    }
    IOObjectRelease(iterator);
    return nits;
}

bool bcpt_touchbar_brightness_read(BCPTTouchBarBrightness *out) {
    if (!out) return false;
    *out = (BCPTTouchBarBrightness){-1, -1, -1, -1};
    @autoreleasepool {
        if (!connectDisplay()) return false;
        SEL get = NSSelectorFromString(@"copyPropertyForKey:andDisplay:");
        if (![core respondsToSelector:get]) return false;
        id properties = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(core, get, @"DisplayBrightness", (uint64_t)displayID);
        id value = [properties isKindOfClass:NSDictionary.class] ? properties[@"Brightness"] : nil;
        double brightness = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : -1;
        if (!isfinite(brightness) || brightness < 0 || brightness > 1) {
            dfr = nil; displayID = -1;
            return false;
        }
        *out = (BCPTTouchBarBrightness){displayID, (int)displayState(), brightness, driverNits()};
        return true;
    }
}

bool bcpt_touchbar_brightness_set(double level) {
    if (!isfinite(level) || level < 0 || level > 1) return false;
    @autoreleasepool {
        if (!connectDisplay() || displayState() != 2) return false;
        SEL set = NSSelectorFromString(@"setProperty:withKey:andDisplay:");
        if (![core respondsToSelector:set]) return false;
        // Preserve macOS/user preferences: this is a temporary display override.
        NSDictionary *properties = @{@"Brightness": @(level), @"Commit": @NO, @"CommitType": @0};
        return ((BOOL (*)(id, SEL, id, id, uint64_t))objc_msgSend)(
            core, set, properties, @"DisplayBrightness", (uint64_t)displayID
        );
    }
}
