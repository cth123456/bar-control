#ifndef POWER_TELEMETRY_SUPPORT_H
#define POWER_TELEMETRY_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BCPTSampler BCPTSampler;

/// Creates a sampler for the private, read-only macOS IOReport Energy Model.
/// Returns NULL when the channels are unavailable on this Mac/macOS version.
BCPTSampler *bcpt_sampler_create(void);

void bcpt_sampler_destroy(BCPTSampler *sampler);

/// Takes the next cumulative-energy sample. The first call establishes a
/// baseline and returns 0; later calls return 1 when a valid delta is ready.
int bcpt_sampler_read(
    BCPTSampler *sampler,
    double *cpu_watts,
    bool *has_cpu,
    double *gpu_watts,
    bool *has_gpu
);

/// Process values use the kernel's billed-energy counter. They are best-effort
/// attribution and intentionally kept separate from the CPU/GPU hardware totals.
int bcpt_sampler_process_count(const BCPTSampler *sampler);
const char *bcpt_sampler_process_name(const BCPTSampler *sampler, int index);
double bcpt_sampler_process_watts(const BCPTSampler *sampler, int index);

/// Reads actual fan RPM values from the read-only AppleSMC F0Ac...F3Ac
/// keys. Returns the number of readable fans, or zero when unavailable.
int bcpt_read_fan_rpms(double *rpms, int capacity);

/// Reads the average of the live GPU temperature sensors exposed through the
/// read-only Apple HID temperature service. Returns 1 when available.
int bcpt_read_gpu_temperature(double *celsius);

#ifdef __cplusplus
}
#endif

#endif
