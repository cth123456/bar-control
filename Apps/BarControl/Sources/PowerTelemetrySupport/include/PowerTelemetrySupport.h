#ifndef POWER_TELEMETRY_SUPPORT_H
#define POWER_TELEMETRY_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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

/// macOS 26+ Manual Charge Limit through the private PowerUI framework.
/// `bcpt_charge_limit_supported` returns 1 when this Mac exposes it.
/// `bcpt_charge_limit_read` returns 1 with the active percentage written to
/// `limit_out`, 0 when no limit is active, or -1 when unavailable.
/// `bcpt_charge_limit_set` enables the limit at `percent` and returns 1 on
/// success. All calls are synchronous and safe to run off the main thread.
int bcpt_charge_limit_supported(void);
int bcpt_charge_limit_read(int *limit_out);
int bcpt_charge_limit_set(int percent);

/// Adapter cut over the AppleSMC CHIE key (0x08 = charger disconnected,
/// 0x00 = reconnected). `bcpt_adapter_control_read` works for any user and
/// returns 1 on success; `bcpt_adapter_control_set` needs root and returns
/// 1 only when the SMC accepted the write.
int bcpt_adapter_control_read(uint8_t *raw_out);
int bcpt_adapter_control_set(uint8_t raw);

#ifdef __cplusplus
}
#endif

#endif
