#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#include "PowerTelemetrySupport.h"

// macOS 26+ routes charge control through the private PowerUI Manual Charge
// Limit instead of the writable AppleSMC charging keys, which firmware
// 20457+ removed or entitlement-gated. The framework is loaded dynamically
// and every selector is probed first, so the app degrades to "unsupported"
// instead of crashing on systems that do not expose it.

static id bcpt_charge_limit_client(void) {
    static id client = nil;
    static int state = 0; // 0 = unknown, 1 = ready, -1 = unavailable
    if (state != 0) {
        return client;
    }
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
        RTLD_NOW
    );
    if (handle == NULL) {
        state = -1;
        return NULL;
    }
    Class client_class = NSClassFromString(@"PowerUISmartChargeClient");
    if (client_class == Nil) {
        state = -1;
        return NULL;
    }
    SEL init_selector = sel_registerName("initWithClientName:");
    if (![client_class instancesRespondToSelector:init_selector]) {
        state = -1;
        return NULL;
    }
    client = ((id (*)(id, SEL, id))objc_msgSend)(
        [client_class alloc],
        init_selector,
        @"BarControl"
    );
    state = client != nil ? 1 : -1;
    return client;
}

static BOOL bcpt_charge_limit_selector_available(id client, const char *name, SEL *out_selector) {
    SEL selector = sel_registerName(name);
    if (![client respondsToSelector:selector]) {
        return NO;
    }
    if (out_selector != NULL) {
        *out_selector = selector;
    }
    return YES;
}

int bcpt_charge_limit_supported(void) {
    id client = bcpt_charge_limit_client();
    if (client == nil) {
        return 0;
    }
    SEL selector = NULL;
    if (!bcpt_charge_limit_selector_available(client, "isMCLSupported", &selector)) {
        return 0;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, selector) ? 1 : 0;
}

int bcpt_charge_limit_read(int *limit_out) {
    @autoreleasepool {
        id client = bcpt_charge_limit_client();
        if (client == nil) {
            return -1;
        }
        SEL enabled_selector = NULL;
        SEL limit_selector = NULL;
        if (!bcpt_charge_limit_selector_available(
                client, "isMCLCurrentlyEnabled:", &enabled_selector)
            || !bcpt_charge_limit_selector_available(
                client, "getMCLLimitWithError:", &limit_selector)) {
            return -1;
        }
        NSError *error = nil;
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(
            client, enabled_selector, &error);
        if (error != nil) {
            return -1;
        }
        if (enabled == 0) {
            if (limit_out != NULL) {
                *limit_out = 0;
            }
            return 0;
        }
        error = nil;
        unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(
            client, limit_selector, &error);
        if (error != nil) {
            return -1;
        }
        if (limit_out != NULL) {
            *limit_out = (int)limit;
        }
        return 1;
    }
}

int bcpt_charge_limit_set(int percent) {
    @autoreleasepool {
        id client = bcpt_charge_limit_client();
        if (client == nil) {
            return 0;
        }
        SEL enable_selector = NULL;
        SEL set_selector = NULL;
        if (!bcpt_charge_limit_selector_available(client, "enableMCL:", &enable_selector)
            || !bcpt_charge_limit_selector_available(client, "setMCLLimit:error:", &set_selector)) {
            return 0;
        }
        NSError *error = nil;
        BOOL enabled = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
            client, enable_selector, &error);
        if (!enabled || error != nil) {
            return 0;
        }
        unsigned char clamped = (unsigned char)(percent < 0 ? 0 : (percent > 100 ? 100 : percent));
        error = nil;
        BOOL applied = ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(
            client, set_selector, clamped, &error);
        return (applied && error == nil) ? 1 : 0;
    }
}
