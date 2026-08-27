// The wire vocabulary of the bootstrap status pipe, declared once for both ends.
//
// The child (`PTYSessionBootstrap`) writes a `bootstrap_failure` here and exits;
// the parent (`TerminalPTYHost/PTYSpawner.swift`) reads it and classifies the
// stage into the candidate ladder the reducer may advance. This header exists so
// that classification reads the same declaration the child wrote from: the stage
// travels as an ordinal, so a second copy of the enum in Swift would let an
// inserted enumerator retire the `requested -> home -> /` fallback chain with
// nothing to report it.
//
// Only the pipe payload belongs here. Which stages are retryable is the parent's
// policy, not the child's, and stays in `PTYSpawner`.
#ifndef PTY_SESSION_BOOTSTRAP_ABI_H
#define PTY_SESSION_BOOTSTRAP_ABI_H

#include <stdint.h>

/// Every point at which the child can refuse a launch, in the order it reaches
/// them. Ordinals are an implementation detail of this declaration -- both ends
/// read the names -- so enumerators may be inserted or reordered freely.
enum bootstrap_stage {
    bootstrap_stage_usage = 1,
    bootstrap_stage_cloexec,
    bootstrap_stage_setsid,
    bootstrap_stage_open_slave,
    bootstrap_stage_controlling_terminal,
    bootstrap_stage_standard_streams,
    bootstrap_stage_foreground_group,
    bootstrap_stage_working_directory,
    bootstrap_stage_exec
};

/// The complete payload of one refusal: fixed-width so the two ends agree on the
/// byte count the parent blocks for.
struct bootstrap_failure {
    int32_t stage;
    int32_t error;
};

#endif
