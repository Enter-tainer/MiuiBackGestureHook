#pragma once

#include <stddef.h>
#include <stdint.h>

namespace miui_home_profiles {

enum class BusinessHookTopology : uint8_t {
    kLegacyThreeStage,
    kSideBoundaryOnly,
};

struct CodeFingerprint {
    uintptr_t offset;
    const uint8_t* bytes;
    size_t size;
};

struct LauncherProfile {
    const char* id;
    const char* version_name;
    uintptr_t image_span;
    uintptr_t entry_offset;
    const CodeFingerprint* identity_fingerprints;
    size_t identity_fingerprint_count;

    BusinessHookTopology business_topology;
    uintptr_t side_handler_offset;
    const uint8_t* side_handler_prologue;
    size_t side_handler_prologue_size;
    uintptr_t side_edge_field_offset;

    uintptr_t pointer_handler_offset;
    const uint8_t* pointer_handler_prologue;
    size_t pointer_handler_prologue_size;
    uintptr_t touch_processor_offset;
    const uint8_t* touch_processor_prologue;
    size_t touch_processor_prologue_size;
    uintptr_t gesture_type_field_offset;

    uintptr_t accepted_pilfer_return_offset;
    uintptr_t home_pilfer_return_offset;
    const uint8_t* accepted_pilfer_caller;
    size_t accepted_pilfer_caller_size;

    uintptr_t rstring_vtable_offset;
    uintptr_t filter_rstring_vtable_offset;
    uintptr_t runtime_pointer_offset;
    uintptr_t runtime_state_offset;
    uint32_t runtime_ready_value;
};

}  // namespace miui_home_profiles
