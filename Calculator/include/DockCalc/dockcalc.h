// dockcalc — dock2's calculator: fend behind a narrow C ABI, a question in and an answer out.
// Implemented in src/lib.rs; driven by Sources/Dock2Calc/Calculator.swift.
#ifndef DOCKCALC_H
#define DOCKCALC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *dc_version(void);

// fend's live answer to `question` (UTF-8), or NULL: an error, the question restated, more than a line, past
// `budget_ms`, or a question past 256 bytes. Never crashes on any input. Free the answer with dc_string_free.
char *dc_answer(const char *question, uint32_t budget_ms, bool comma_decimals);
void dc_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
