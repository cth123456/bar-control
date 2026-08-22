#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void PrintMethods(Class cls, const char *prefix) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        SEL selector = method_getName(methods[index]);
        const char *types = method_getTypeEncoding(methods[index]);
        printf("%s %s %s\n", prefix, sel_getName(selector), types ?: "?");
    }
    free(methods);
}

int main(void) {
    @autoreleasepool {
        NSString *frameworkPath = @"/System/Library/PrivateFrameworks/DFRBrightness.framework";
        NSBundle *bundle = [NSBundle bundleWithPath:frameworkPath];
        printf("bundle.loaded.before=%s\n", bundle.loaded ? "true" : "false");
        NSError *error = nil;
        BOOL loaded = [bundle loadAndReturnError:&error];
        printf("bundle.loaded.after=%s result=%s\n", bundle.loaded ? "true" : "false", loaded ? "true" : "false");
        if (error) {
            printf("bundle.load.error=%s\n", error.localizedDescription.UTF8String);
        }

        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
        count = objc_getClassList(classes, count);
        for (int index = 0; index < count; index++) {
            Class cls = classes[index];
            const char *name = class_getName(cls);
            NSString *className = [NSString stringWithUTF8String:name ?: ""];
            if ([className rangeOfString:@"DFR" options:NSCaseInsensitiveSearch].location == NSNotFound
                && [className rangeOfString:@"Brightness" options:NSCaseInsensitiveSearch].location == NSNotFound
                && [className rangeOfString:@"TouchBar" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                continue;
            }
            printf("class %s\n", name);
            PrintMethods(cls, "  -");
            PrintMethods(object_getClass(cls), "  +");
        }
        free(classes);
    }
    return 0;
}
