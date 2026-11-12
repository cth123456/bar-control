#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "PowerTelemetrySupport.h"

// Read an already trusted, USB-connected device; never pair or request trust.
typedef struct { void *device; uint32_t message; } DeviceNotice;
typedef int (*DeviceCall)(void *);
typedef CFStringRef (*CopyIdentifier)(void *);
typedef CFTypeRef (*CopyValue)(void *, CFStringRef, CFStringRef);
typedef void (*NoticeCallback)(DeviceNotice *, void *);
typedef int (*Subscribe)(NoticeCallback, uint32_t, uint32_t, void *, void **);
typedef int (*Unsubscribe)(void *);

typedef struct {
    DeviceCall connect, paired, validate, start, stop, disconnect;
    CopyIdentifier identifier;
    CopyValue value;
    __unsafe_unretained NSString *serial;
    int percent;
} BatteryRead;

static NSString *normalized(NSString *value) {
    return [[value stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
}

static void deviceConnected(DeviceNotice *notice, void *context) {
    BatteryRead *read = context;
    if (notice->message != 1 || read->percent >= 0) return;
    void *device = notice->device;
    CFStringRef identifier = read->identifier(device);
    if (!identifier) return;
    BOOL matches = [normalized((__bridge NSString *)identifier) isEqualToString:read->serial];
    CFRelease(identifier);
    if (!matches || read->connect(device) != 0) return;
    BOOL session = NO;
    @try {
        if (!read->paired(device) || read->validate(device) != 0) return;
        if (read->start(device) != 0) return;
        session = YES;
        CFTypeRef value = read->value(device, CFSTR("com.apple.mobile.battery"), CFSTR("BatteryCurrentCapacity"));
        if (value) {
            int percent = -1;
            if (CFGetTypeID(value) == CFNumberGetTypeID() &&
                CFNumberGetValue(value, kCFNumberIntType, &percent) && percent >= 0 && percent <= 100) {
                read->percent = percent;
            }
            CFRelease(value);
        }
    } @finally {
        if (session) read->stop(device);
        read->disconnect(device);
    }
}

int bcpt_read_external_battery(const char *usb_serial) {
    if (!usb_serial || !*usb_serial) return -1;
    @autoreleasepool {
        static void *handle;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY);
        });
        if (!handle) return -1;
        BatteryRead read = {
            .connect = dlsym(handle, "AMDeviceConnect"),
            .paired = dlsym(handle, "AMDeviceIsPaired"),
            .validate = dlsym(handle, "AMDeviceValidatePairing"),
            .start = dlsym(handle, "AMDeviceStartSession"),
            .stop = dlsym(handle, "AMDeviceStopSession"),
            .disconnect = dlsym(handle, "AMDeviceDisconnect"),
            .identifier = dlsym(handle, "AMDeviceCopyDeviceIdentifier"),
            .value = dlsym(handle, "AMDeviceCopyValue"),
            .percent = -1
        };
        Subscribe subscribe = dlsym(handle, "AMDeviceNotificationSubscribe");
        Unsubscribe unsubscribe = dlsym(handle, "AMDeviceNotificationUnsubscribe");
        NSString *serial = normalized([NSString stringWithUTF8String:usb_serial]);
        read.serial = serial;
        if (read.connect && read.paired && read.validate && read.start && read.stop &&
            read.disconnect && read.identifier && read.value && subscribe && unsubscribe) {
            void *subscription = NULL;
            if (subscribe(deviceConnected, 0, 0, &read, &subscription) == 0) {
                // Existing-device notifications arrive on this worker's run loop.
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
                unsubscribe(subscription);
            }
        }
        return read.percent;
    }
}
