#import <Foundation/Foundation.h>
#import <objc/message.h>

typedef NSInteger (*IntegerMessage)(id, SEL);
typedef BOOL (*BoolMessage)(id, SEL);
typedef BOOL (*IntegerArgumentMessage)(id, SEL, NSInteger);
typedef BOOL (*IntegerFloatFloatMessage)(id, SEL, NSInteger, float, float);

static NSInteger SendInteger(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return ((IntegerMessage)objc_msgSend)(object, selector);
}

static BOOL SendBool(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return ((BoolMessage)objc_msgSend)(object, selector);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/DFRBrightness.framework"];
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "load failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        Class clientClass = NSClassFromString(@"DFRBrightnessClient");
        id client = [[clientClass alloc] init];
        if (!client) {
            fprintf(stderr, "unable to create DFRBrightnessClient\n");
            return 2;
        }

        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"status";
        if ([mode isEqualToString:@"turn-on"]) {
            printf("turnOn=%s\n", SendBool(client, @"turnOn") ? "true" : "false");
        } else if ([mode isEqualToString:@"step"] && argc > 2) {
            NSInteger step = [[NSString stringWithUTF8String:argv[2]] integerValue];
            BOOL result = ((IntegerArgumentMessage)objc_msgSend)(client, NSSelectorFromString(@"dimToStep:"), step);
            printf("dimToStep(%ld)=%s\n", (long)step, result ? "true" : "false");
        } else if ([mode isEqualToString:@"ramp"] && argc > 4) {
            NSInteger step = [[NSString stringWithUTF8String:argv[2]] integerValue];
            float period = [[NSString stringWithUTF8String:argv[3]] floatValue];
            float coefficient = [[NSString stringWithUTF8String:argv[4]] floatValue];
            BOOL result = ((IntegerFloatFloatMessage)objc_msgSend)(
                client,
                NSSelectorFromString(@"dimToStep:withPeriod:andCoefficient:"),
                step,
                period,
                coefficient
            );
            printf("ramp(step=%ld period=%.2f coefficient=%.2f)=%s\n", (long)step, period, coefficient, result ? "true" : "false");
        }

        printf("displayState=%ld\n", (long)SendInteger(client, @"displayState"));
        printf("dimmingStep=%ld\n", (long)SendInteger(client, @"getDimmingStep"));
        printf("harmonyState=%ld\n", (long)SendInteger(client, @"harmonyState"));
    }
    return 0;
}
