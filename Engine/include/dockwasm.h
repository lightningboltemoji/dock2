// dockwasm — dock2's plugin engine: a narrow C ABI over wasmtime, shaped like the plugin actor model.
// Implemented in src/lib.rs; driven by Sources/Dock2Plugins/PluginEngine.swift.
#ifndef DOCKWASM_H
#define DOCKWASM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DwEngine dw_engine;
typedef struct DwModule dw_module;
typedef struct DwInstance dw_instance;

typedef enum {
  DW_OK = 0,
  DW_DEADLINE = 1, // the budget ran out; the call was interrupted
  DW_MEMORY = 2,   // the guest trapped after its memory cap refused to grow
  DW_TRAP = 3,     // any other trap: unreachable, out of bounds, stack overflow
  DW_ERROR = 4,    // the host's side failed: a bad result range, a poisoned instance
} dw_status;

// The guest's dock2.log(level, ptr, len).
typedef void (*dw_log_fn)(void *ctx, int32_t level, const uint8_t *ptr, size_t len);

const char *dw_version(void);

// Errors come back through `err` as a C string the caller frees with dw_string_free.
dw_engine *dw_engine_new(char **err);
void dw_engine_free(dw_engine *engine);

dw_module *dw_module_compile(const dw_engine *engine, const uint8_t *wasm, size_t len, char **err);
int32_t dw_module_serialize(const dw_module *module, uint8_t **out, size_t *out_len, char **err);
// Only bytes dw_module_serialize made, with this same engine: never a plugin author's.
dw_module *dw_module_deserialize(const dw_engine *engine, const uint8_t *bytes, size_t len, char **err);
void dw_module_free(dw_module *module);

dw_instance *dw_instance_new(const dw_engine *engine, const dw_module *module, uint64_t memory_cap,
                             dw_log_fn log, void *log_ctx, char **err);
// On DW_OK *out is the effects JSON; otherwise a description of the failure. Free it with dw_bytes_free.
// Any status but DW_OK poisons the instance: free it, and instantiate again.
dw_status dw_instance_call(dw_instance *instance, const uint8_t *event, size_t len, uint32_t budget_ms,
                           uint8_t **out, size_t *out_len);
void dw_instance_free(dw_instance *instance);

// Key derivation, done natively for plugins: slow by design, past what an interpreted call may spend.
// 0 on success.
int32_t dw_pbkdf2_sha256(const uint8_t *password, size_t password_len, const uint8_t *salt, size_t salt_len,
                         uint32_t iterations, uint8_t *out, size_t out_len);
int32_t dw_argon2id(const uint8_t *password, size_t password_len, const uint8_t *salt, size_t salt_len,
                    uint32_t iterations, uint32_t memory_kib, uint32_t parallelism, uint8_t *out, size_t out_len);

void dw_bytes_free(uint8_t *ptr, size_t len);
void dw_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
