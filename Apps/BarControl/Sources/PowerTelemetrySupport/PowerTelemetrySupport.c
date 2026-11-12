#include "PowerTelemetrySupport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(
    IOHIDEventSystemClientRef client,
    CFDictionaryRef matching
);
typedef void *BCPTIOHIDEventRef;
extern BCPTIOHIDEventRef IOHIDServiceClientCopyEvent(
    IOHIDServiceClientRef service,
    int64_t type,
    int32_t options,
    int64_t timeout
);
extern double IOHIDEventGetFloatValue(BCPTIOHIDEventRef event, int64_t field);

static pthread_mutex_t bcpt_gpu_temperature_lock = PTHREAD_MUTEX_INITIALIZER;
static IOHIDEventSystemClientRef bcpt_gpu_temperature_client = NULL;
static CFDictionaryRef bcpt_gpu_temperature_matching = NULL;

typedef CFDictionaryRef (*CopyChannelsInGroupFn)(
    CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t
);
typedef void (*MergeChannelsFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef const void *(*CreateSubscriptionFn)(
    const void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef
);
typedef CFDictionaryRef (*CreateSamplesFn)(
    const void *, CFMutableDictionaryRef, CFTypeRef
);
typedef CFDictionaryRef (*CreateSamplesDeltaFn)(
    CFDictionaryRef, CFDictionaryRef, CFTypeRef
);
typedef CFStringRef (*ChannelStringFn)(CFDictionaryRef);
typedef int64_t (*SimpleIntegerValueFn)(CFDictionaryRef, int32_t);

typedef int32_t (*ProcListAllPIDsFn)(int32_t *, int32_t);
typedef int32_t (*ProcPIDRUsageFn)(int32_t, int32_t, uint8_t *);
typedef int32_t (*ProcNameFn)(int32_t, void *, uint32_t);

enum {
    BCPT_MAX_PROCESSES = 4096,
    BCPT_PROCESS_NAME_BYTES = 96,
    BCPT_RESULT_COUNT = 12,
    BCPT_RUSAGE_INFO_V4 = 4,
    BCPT_RUSAGE_V4_SIZE = 296,
    BCPT_BILLED_ENERGY_OFFSET = 264
};

typedef struct {
    int32_t pid;
    uint64_t energy_nj;
    char name[BCPT_PROCESS_NAME_BYTES];
} BCPTProcessState;

typedef struct {
    int32_t pid;
    char name[BCPT_PROCESS_NAME_BYTES];
    double watts;
} BCPTProcessResult;

// Read-only AppleSMC ABI used for actual fan-speed keys. This deliberately
// exposes no write operation or fan-control mode.
typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} BCPTSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_limit;
    uint32_t gpu_limit;
    uint32_t memory_limit;
} BCPTSMCPowerLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t attributes;
} BCPTSMCKeyInfo;

typedef struct {
    uint32_t key;
    BCPTSMCVersion version;
    BCPTSMCPowerLimit power_limit;
    BCPTSMCKeyInfo key_info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} BCPTSMCKeyData;

struct BCPTSampler {
    void *io_report_handle;
    void *libproc_handle;
    CopyChannelsInGroupFn copy_channels;
    MergeChannelsFn merge_channels;
    CreateSubscriptionFn create_subscription;
    CreateSamplesFn create_samples;
    CreateSamplesDeltaFn create_delta;
    ChannelStringFn channel_group;
    ChannelStringFn channel_name;
    ChannelStringFn channel_unit;
    SimpleIntegerValueFn channel_integer;
    ProcListAllPIDsFn proc_list_all_pids;
    ProcPIDRUsageFn proc_pid_rusage;
    ProcNameFn proc_name;
    const void *subscription;
    CFMutableDictionaryRef subscribed_channels;
    CFDictionaryRef previous_sample;
    struct timespec previous_time;
    double previous_cpu_joules;
    double previous_gpu_joules;
    bool has_previous_cpu;
    bool has_previous_gpu;
    BCPTProcessState *previous_processes;
    int previous_process_count;
    BCPTProcessResult process_results[BCPT_RESULT_COUNT];
    int process_result_count;
};

static void *bcpt_symbol(void *handle, const char *name) {
    return handle == NULL ? NULL : dlsym(handle, name);
}

static double bcpt_elapsed_seconds(struct timespec start, struct timespec end) {
    double seconds = (double)(end.tv_sec - start.tv_sec);
    seconds += (double)(end.tv_nsec - start.tv_nsec) / 1000000000.0;
    return seconds;
}

static bool bcpt_copy_cfstring(CFStringRef string, char *buffer, size_t capacity) {
    if (string == NULL || buffer == NULL || capacity == 0) {
        return false;
    }
    buffer[0] = '\0';
    return CFStringGetCString(string, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
}

static double bcpt_energy_to_joules(int64_t value, const char *unit) {
    if (value <= 0 || unit == NULL) {
        return 0.0;
    }
    if (strcmp(unit, "mJ") == 0) {
        return (double)value / 1000.0;
    }
    if (strcmp(unit, "uJ") == 0) {
        return (double)value / 1000000.0;
    }
    if (strcmp(unit, "nJ") == 0) {
        return (double)value / 1000000000.0;
    }
    return 0.0;
}

static bool bcpt_ends_with(const char *value, const char *suffix) {
    if (value == NULL || suffix == NULL) {
        return false;
    }
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    return value_length >= suffix_length
        && strcmp(value + value_length - suffix_length, suffix) == 0;
}

static uint64_t bcpt_read_u64(const uint8_t *bytes, size_t offset) {
    uint64_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

static void bcpt_read_cumulative_energy(
    BCPTSampler *sampler,
    CFDictionaryRef sample,
    double *cpu_joules,
    bool *has_cpu,
    double *gpu_joules,
    bool *has_gpu
) {
    *cpu_joules = 0.0;
    *gpu_joules = 0.0;
    *has_cpu = false;
    *has_gpu = false;
    CFArrayRef channel_array = (CFArrayRef)CFDictionaryGetValue(
        sample, CFSTR("IOReportChannels")
    );
    if (channel_array == NULL) {
        return;
    }
    CFIndex count = CFArrayGetCount(channel_array);
    for (CFIndex index = 0; index < count; index++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(
            channel_array, index
        );
        char group[64];
        char name[128];
        char unit[16];
        if (!bcpt_copy_cfstring(sampler->channel_group(channel), group, sizeof(group))
            || strcmp(group, "Energy Model") != 0
            || !bcpt_copy_cfstring(sampler->channel_name(channel), name, sizeof(name))
            || !bcpt_copy_cfstring(sampler->channel_unit(channel), unit, sizeof(unit))) {
            continue;
        }
        int64_t value = sampler->channel_integer(channel, 0);
        double joules = bcpt_energy_to_joules(value, unit);
        if (getenv("BARCONTROL_POWER_DEBUG") != NULL
            && (bcpt_ends_with(name, "CPU Energy") || strcmp(name, "GPU Energy") == 0)) {
            fprintf(stderr, "Energy Model cumulative: %s [%s] = %lld\n", name, unit, value);
        }
        if (bcpt_ends_with(name, "CPU Energy")) {
            *cpu_joules += joules;
            *has_cpu = value > 0;
        } else if (strcmp(name, "GPU Energy") == 0) {
            *gpu_joules += joules;
            *has_gpu = value > 0;
        }
    }
}

static int bcpt_process_result_compare(const void *left, const void *right) {
    const BCPTProcessResult *a = left;
    const BCPTProcessResult *b = right;
    if (a->watts < b->watts) {
        return 1;
    }
    if (a->watts > b->watts) {
        return -1;
    }
    return strcmp(a->name, b->name);
}

static BCPTProcessState *bcpt_read_processes(BCPTSampler *sampler, int *count) {
    *count = 0;
    if (sampler->proc_list_all_pids == NULL
        || sampler->proc_pid_rusage == NULL
        || sampler->proc_name == NULL) {
        return NULL;
    }

    int32_t *pids = calloc(BCPT_MAX_PROCESSES, sizeof(int32_t));
    BCPTProcessState *states = calloc(BCPT_MAX_PROCESSES, sizeof(BCPTProcessState));
    if (pids == NULL || states == NULL) {
        free(pids);
        free(states);
        return NULL;
    }

    int32_t pid_count = sampler->proc_list_all_pids(
        pids,
        (int32_t)(BCPT_MAX_PROCESSES * sizeof(int32_t))
    );
    if (pid_count <= 0) {
        free(pids);
        free(states);
        return NULL;
    }

    uint8_t usage[BCPT_RUSAGE_V4_SIZE];
    char name[BCPT_PROCESS_NAME_BYTES];
    int state_count = 0;
    int limit = pid_count < BCPT_MAX_PROCESSES ? pid_count : BCPT_MAX_PROCESSES;
    for (int index = 0; index < limit; index++) {
        int32_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }
        memset(usage, 0, sizeof(usage));
        if (sampler->proc_pid_rusage(pid, BCPT_RUSAGE_INFO_V4, usage) != 0) {
            continue;
        }
        uint64_t energy = bcpt_read_u64(usage, BCPT_BILLED_ENERGY_OFFSET);
        if (energy == 0) {
            continue;
        }
        memset(name, 0, sizeof(name));
        if (sampler->proc_name(pid, name, (uint32_t)sizeof(name)) <= 0 || name[0] == '\0') {
            continue;
        }
        states[state_count].pid = pid;
        states[state_count].energy_nj = energy;
        strlcpy(states[state_count].name, name, sizeof(states[state_count].name));
        state_count++;
    }
    free(pids);
    *count = state_count;
    return states;
}

static void bcpt_update_process_results(
    BCPTSampler *sampler,
    BCPTProcessState *current,
    int current_count,
    double elapsed
) {
    sampler->process_result_count = 0;
    memset(sampler->process_results, 0, sizeof(sampler->process_results));
    if (current == NULL || elapsed <= 0.0) {
        return;
    }

    BCPTProcessResult *candidates = calloc((size_t)current_count, sizeof(BCPTProcessResult));
    if (candidates == NULL) {
        return;
    }
    int candidate_count = 0;
    for (int index = 0; index < current_count; index++) {
        const BCPTProcessState *item = &current[index];
        const BCPTProcessState *previous = NULL;
        for (int old_index = 0; old_index < sampler->previous_process_count; old_index++) {
            const BCPTProcessState *old = &sampler->previous_processes[old_index];
            if (old->pid == item->pid && strcmp(old->name, item->name) == 0) {
                previous = old;
                break;
            }
        }
        if (previous == NULL || item->energy_nj <= previous->energy_nj) {
            continue;
        }
        double watts = (double)(item->energy_nj - previous->energy_nj)
            / 1000000000.0 / elapsed;
        if (!isfinite(watts) || watts < 0.001) {
            continue;
        }
        strlcpy(candidates[candidate_count].name, item->name, BCPT_PROCESS_NAME_BYTES);
        candidates[candidate_count].pid = item->pid;
        candidates[candidate_count].watts = watts;
        candidate_count++;
    }
    qsort(
        candidates,
        (size_t)candidate_count,
        sizeof(BCPTProcessResult),
        bcpt_process_result_compare
    );
    sampler->process_result_count = candidate_count < BCPT_RESULT_COUNT
        ? candidate_count
        : BCPT_RESULT_COUNT;
    memcpy(
        sampler->process_results,
        candidates,
        (size_t)sampler->process_result_count * sizeof(BCPTProcessResult)
    );
    free(candidates);
}

BCPTSampler *bcpt_sampler_create(void) {
    BCPTSampler *sampler = calloc(1, sizeof(BCPTSampler));
    if (sampler == NULL) {
        return NULL;
    }

    sampler->io_report_handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    sampler->libproc_handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL);
    sampler->copy_channels = (CopyChannelsInGroupFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportCopyChannelsInGroup"
    );
    sampler->merge_channels = (MergeChannelsFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportMergeChannels"
    );
    sampler->create_subscription = (CreateSubscriptionFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportCreateSubscription"
    );
    sampler->create_samples = (CreateSamplesFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportCreateSamples"
    );
    sampler->create_delta = (CreateSamplesDeltaFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportCreateSamplesDelta"
    );
    sampler->channel_group = (ChannelStringFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportChannelGetGroup"
    );
    sampler->channel_name = (ChannelStringFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportChannelGetChannelName"
    );
    sampler->channel_unit = (ChannelStringFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportChannelGetUnitLabel"
    );
    sampler->channel_integer = (SimpleIntegerValueFn)bcpt_symbol(
        sampler->io_report_handle, "IOReportSimpleGetIntegerValue"
    );
    sampler->proc_list_all_pids = (ProcListAllPIDsFn)bcpt_symbol(
        sampler->libproc_handle, "proc_listallpids"
    );
    sampler->proc_pid_rusage = (ProcPIDRUsageFn)bcpt_symbol(
        sampler->libproc_handle, "proc_pid_rusage"
    );
    sampler->proc_name = (ProcNameFn)bcpt_symbol(sampler->libproc_handle, "proc_name");

    if (sampler->copy_channels == NULL
        || sampler->create_subscription == NULL
        || sampler->create_samples == NULL
        || sampler->create_delta == NULL
        || sampler->channel_group == NULL
        || sampler->channel_name == NULL
        || sampler->channel_unit == NULL
        || sampler->channel_integer == NULL) {
        bcpt_sampler_destroy(sampler);
        return NULL;
    }

    CFDictionaryRef channels = sampler->copy_channels(
        CFSTR("Energy Model"), NULL, 0, 0, 0
    );
    if (channels == NULL) {
        bcpt_sampler_destroy(sampler);
        return NULL;
    }
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault,
        CFDictionaryGetCount(channels),
        channels
    );
    CFRelease(channels);
    if (desired == NULL) {
        bcpt_sampler_destroy(sampler);
        return NULL;
    }

    CFMutableDictionaryRef subscribed = NULL;
    sampler->subscription = sampler->create_subscription(
        NULL, desired, &subscribed, 0, NULL
    );
    CFRelease(desired);
    if (sampler->subscription == NULL || subscribed == NULL) {
        bcpt_sampler_destroy(sampler);
        return NULL;
    }
    sampler->subscribed_channels = subscribed;
    return sampler;
}

void bcpt_sampler_destroy(BCPTSampler *sampler) {
    if (sampler == NULL) {
        return;
    }
    if (sampler->previous_sample != NULL) {
        CFRelease(sampler->previous_sample);
    }
    if (sampler->subscribed_channels != NULL) {
        CFRelease(sampler->subscribed_channels);
    }
    if (sampler->subscription != NULL) {
        CFRelease(sampler->subscription);
    }
    free(sampler->previous_processes);
    if (sampler->io_report_handle != NULL) {
        dlclose(sampler->io_report_handle);
    }
    if (sampler->libproc_handle != NULL) {
        dlclose(sampler->libproc_handle);
    }
    free(sampler);
}

int bcpt_sampler_read(
    BCPTSampler *sampler,
    double *cpu_watts,
    bool *has_cpu,
    double *gpu_watts,
    bool *has_gpu
) {
    if (sampler == NULL || cpu_watts == NULL || has_cpu == NULL
        || gpu_watts == NULL || has_gpu == NULL) {
        return 0;
    }
    *cpu_watts = 0.0;
    *gpu_watts = 0.0;
    *has_cpu = false;
    *has_gpu = false;

    CFDictionaryRef current = sampler->create_samples(
        sampler->subscription, sampler->subscribed_channels, NULL
    );
    if (current == NULL) {
        return 0;
    }
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    int current_process_count = 0;
    BCPTProcessState *current_processes = bcpt_read_processes(
        sampler, &current_process_count
    );

    double cumulative_cpu_joules = 0.0;
    double cumulative_gpu_joules = 0.0;
    bool current_has_cpu = false;
    bool current_has_gpu = false;
    bcpt_read_cumulative_energy(
        sampler,
        current,
        &cumulative_cpu_joules,
        &current_has_cpu,
        &cumulative_gpu_joules,
        &current_has_gpu
    );

    if (sampler->previous_sample == NULL) {
        sampler->previous_sample = current;
        sampler->previous_time = now;
        sampler->previous_cpu_joules = cumulative_cpu_joules;
        sampler->previous_gpu_joules = cumulative_gpu_joules;
        sampler->has_previous_cpu = current_has_cpu;
        sampler->has_previous_gpu = current_has_gpu;
        free(sampler->previous_processes);
        sampler->previous_processes = current_processes;
        sampler->previous_process_count = current_process_count;
        return 0;
    }

    double elapsed = bcpt_elapsed_seconds(sampler->previous_time, now);
    if (elapsed > 0.05) {
        if (current_has_cpu
            && sampler->has_previous_cpu
            && cumulative_cpu_joules >= sampler->previous_cpu_joules) {
            *cpu_watts = (cumulative_cpu_joules - sampler->previous_cpu_joules) / elapsed;
            *has_cpu = isfinite(*cpu_watts) && *cpu_watts > 0.0;
        }
        if (current_has_gpu
            && sampler->has_previous_gpu
            && cumulative_gpu_joules >= sampler->previous_gpu_joules) {
            *gpu_watts = (cumulative_gpu_joules - sampler->previous_gpu_joules) / elapsed;
            *has_gpu = isfinite(*gpu_watts) && *gpu_watts > 0.0;
        }
        bcpt_update_process_results(
            sampler, current_processes, current_process_count, elapsed
        );
    }
    CFRelease(sampler->previous_sample);
    sampler->previous_sample = current;
    sampler->previous_time = now;
    sampler->previous_cpu_joules = cumulative_cpu_joules;
    sampler->previous_gpu_joules = cumulative_gpu_joules;
    sampler->has_previous_cpu = current_has_cpu;
    sampler->has_previous_gpu = current_has_gpu;
    free(sampler->previous_processes);
    sampler->previous_processes = current_processes;
    sampler->previous_process_count = current_process_count;
    return (*has_cpu || *has_gpu) ? 1 : 0;
}

int bcpt_sampler_process_count(const BCPTSampler *sampler) {
    return sampler == NULL ? 0 : sampler->process_result_count;
}

const char *bcpt_sampler_process_name(const BCPTSampler *sampler, int index) {
    if (sampler == NULL || index < 0 || index >= sampler->process_result_count) {
        return NULL;
    }
    return sampler->process_results[index].name;
}

int32_t bcpt_sampler_process_pid(const BCPTSampler *sampler, int index) {
    if (sampler == NULL || index < 0 || index >= sampler->process_result_count) return 0;
    return sampler->process_results[index].pid;
}

double bcpt_sampler_process_watts(const BCPTSampler *sampler, int index) {
    if (sampler == NULL || index < 0 || index >= sampler->process_result_count) {
        return 0.0;
    }
    return sampler->process_results[index].watts;
}

static uint32_t bcpt_smc_code(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24)
        | ((uint32_t)(uint8_t)key[1] << 16)
        | ((uint32_t)(uint8_t)key[2] << 8)
        | (uint32_t)(uint8_t)key[3];
}

static bool bcpt_smc_read(
    io_connect_t connection,
    const char key[4],
    BCPTSMCKeyData *value
) {
    if (connection == IO_OBJECT_NULL || key == NULL || value == NULL) {
        return false;
    }
    BCPTSMCKeyData input;
    BCPTSMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    memset(value, 0, sizeof(*value));
    input.key = bcpt_smc_code(key);
    input.command = 9;
    size_t output_size = sizeof(output);
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        2,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0
        || output.key_info.data_size == 0 || output.key_info.data_size > 32) {
        return false;
    }

    input.key_info = output.key_info;
    input.command = 5;
    memset(&output, 0, sizeof(output));
    output_size = sizeof(output);
    result = IOConnectCallStructMethod(
        connection,
        2,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0) {
        return false;
    }
    output.key_info = input.key_info;
    *value = output;
    return true;
}

static bool bcpt_smc_decode_rpm(const BCPTSMCKeyData *value, double *rpm) {
    if (value == NULL || rpm == NULL) {
        return false;
    }
    const uint32_t type_float = bcpt_smc_code("flt ");
    const uint32_t type_fixed_e2 = bcpt_smc_code("fpe2");
    const uint32_t type_uint16 = bcpt_smc_code("ui16");
    double decoded = NAN;
    if (value->key_info.data_type == type_float && value->key_info.data_size >= 4) {
        float native_value = 0;
        memcpy(&native_value, value->bytes, sizeof(native_value));
        decoded = (double)native_value;
    } else if (value->key_info.data_type == type_fixed_e2
        && value->key_info.data_size >= 2) {
        uint16_t raw = ((uint16_t)value->bytes[0] << 8) | value->bytes[1];
        decoded = (double)raw / 4.0;
    } else if (value->key_info.data_type == type_uint16
        && value->key_info.data_size >= 2) {
        uint16_t raw = ((uint16_t)value->bytes[0] << 8) | value->bytes[1];
        decoded = (double)raw;
    }
    if (!isfinite(decoded) || decoded < 0 || decoded > 30000) {
        return false;
    }
    *rpm = decoded;
    return true;
}

int bcpt_read_fan_rpms(double *rpms, int capacity) {
    if (rpms == NULL || capacity <= 0) {
        return 0;
    }
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return 0;
    }
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t open_result = IOServiceOpen(
        service,
        mach_task_self(),
        0,
        &connection
    );
    IOObjectRelease(service);
    if (open_result != KERN_SUCCESS || connection == IO_OBJECT_NULL) {
        return 0;
    }

    int count = 0;
    int limit = capacity < 4 ? capacity : 4;
    for (int index = 0; index < limit; index++) {
        char key[5] = {'F', (char)('0' + index), 'A', 'c', '\0'};
        BCPTSMCKeyData value;
        double rpm = 0;
        if (bcpt_smc_read(connection, key, &value)
            && bcpt_smc_decode_rpm(&value, &rpm)) {
            rpms[count++] = rpm;
        }
    }
    IOServiceClose(connection);
    return count;
}

static bool bcpt_smc_write(
    io_connect_t connection,
    const char key[4],
    const uint8_t *bytes,
    uint32_t size
) {
    if (connection == IO_OBJECT_NULL || key == NULL || bytes == NULL
        || size == 0 || size > 32) {
        return false;
    }
    BCPTSMCKeyData input;
    BCPTSMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = bcpt_smc_code(key);
    input.command = 9;
    size_t output_size = sizeof(output);
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        2,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0) {
        return false;
    }
    input.key_info = output.key_info;
    memcpy(input.bytes, bytes, size);
    input.command = 6;
    memset(&output, 0, sizeof(output));
    output_size = sizeof(output);
    result = IOConnectCallStructMethod(
        connection,
        2,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS) {
        return false;
    }
    return output.result == 0;
}

static io_connect_t bcpt_open_smc(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t open_result = IOServiceOpen(
        service,
        mach_task_self(),
        0,
        &connection
    );
    IOObjectRelease(service);
    if (open_result != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    return connection;
}

// The adapter cut lives on the CHIE key: 0x08 disconnects the charger even
// while it stays plugged in, 0x00 reconnects it. Reads work for any user;
// writes historically require root, and firmware 20457+ may refuse them
// entirely, so every write is verified by a read-back at the call site.
int bcpt_adapter_control_read(uint8_t *raw_out) {
    io_connect_t connection = bcpt_open_smc();
    if (connection == IO_OBJECT_NULL) {
        return 0;
    }
    BCPTSMCKeyData value;
    int success = 0;
    if (bcpt_smc_read(connection, "CHIE", &value)
        && value.key_info.data_size >= 1) {
        if (raw_out != NULL) {
            *raw_out = value.bytes[0];
        }
        success = 1;
    }
    IOServiceClose(connection);
    return success;
}

int bcpt_adapter_control_set(uint8_t raw) {
    io_connect_t connection = bcpt_open_smc();
    if (connection == IO_OBJECT_NULL) {
        return 0;
    }
    uint8_t byte = raw;
    int success = bcpt_smc_write(connection, "CHIE", &byte, 1) ? 1 : 0;
    IOServiceClose(connection);
    return success;
}

static bool bcpt_prepare_gpu_temperature_client(void) {
    if (bcpt_gpu_temperature_client != NULL) {
        return true;
    }
    int page = 0xff00;
    int usage = 0x0005;
    CFNumberRef page_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &page
    );
    CFNumberRef usage_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &usage
    );
    if (page_number == NULL || usage_number == NULL) {
        if (page_number != NULL) CFRelease(page_number);
        if (usage_number != NULL) CFRelease(usage_number);
        return false;
    }

    const void *keys[2] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[2] = {page_number, usage_number};
    CFDictionaryRef matching = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(page_number);
    CFRelease(usage_number);
    if (matching == NULL) {
        return false;
    }

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) {
        CFRelease(matching);
        return false;
    }
    IOHIDEventSystemClientSetMatching(client, matching);
    bcpt_gpu_temperature_client = client;
    bcpt_gpu_temperature_matching = matching;
    return true;
}

int bcpt_read_gpu_temperature(double *celsius) {
    if (celsius == NULL) {
        return 0;
    }
    *celsius = 0;
    pthread_mutex_lock(&bcpt_gpu_temperature_lock);
    if (!bcpt_prepare_gpu_temperature_client()) {
        pthread_mutex_unlock(&bcpt_gpu_temperature_lock);
        return 0;
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(
        bcpt_gpu_temperature_client
    );
    if (services == NULL) {
        pthread_mutex_unlock(&bcpt_gpu_temperature_lock);
        return 0;
    }

    double sum = 0;
    int count = 0;
    CFIndex service_count = CFArrayGetCount(services);
    for (CFIndex index = 0; index < service_count; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(
            services,
            index
        );
        if (service == NULL) {
            continue;
        }
        CFStringRef product_ref = IOHIDServiceClientCopyProperty(
            service,
            CFSTR("Product")
        );
        if (product_ref == NULL) {
            continue;
        }
        char product[256] = {0};
        bool is_gpu = CFStringGetCString(
            product_ref,
            product,
            sizeof(product),
            kCFStringEncodingUTF8
        ) && strstr(product, "GPU") != NULL;
        CFRelease(product_ref);
        if (!is_gpu) {
            continue;
        }

        BCPTIOHIDEventRef event = IOHIDServiceClientCopyEvent(
            service,
            15,
            0,
            0
        );
        if (event == NULL) {
            continue;
        }
        double temperature = IOHIDEventGetFloatValue(event, 15 << 16);
        CFRelease(event);
        if (isfinite(temperature) && temperature > 10 && temperature < 150) {
            sum += temperature;
            count++;
        }
    }

    CFRelease(services);
    if (count == 0) {
        pthread_mutex_unlock(&bcpt_gpu_temperature_lock);
        return 0;
    }
    *celsius = sum / (double)count;
    pthread_mutex_unlock(&bcpt_gpu_temperature_lock);
    return 1;
}
