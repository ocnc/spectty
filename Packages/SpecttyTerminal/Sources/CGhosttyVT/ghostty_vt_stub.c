// Stub implementations for libghostty-vt C API.
// Replaced by the real library when linked.
// No-op behavior that allows the Swift code to compile.

#include "include/ghostty/ghostty_vt.h"
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// SGR Stubs
// ---------------------------------------------------------------------------

void ghostty_sgr_init(ghostty_sgr_state_t *state) {
    memset(state, 0, sizeof(*state));
    state->fg.type = GHOSTTY_COLOR_TYPE_DEFAULT;
    state->bg.type = GHOSTTY_COLOR_TYPE_DEFAULT;
}

void ghostty_sgr_parse(ghostty_sgr_state_t *state,
                       const uint16_t *params,
                       size_t count) {
    // Stub: real implementation will come from libghostty-vt.
    // For now, handle basic SGR codes inline in Swift.
    (void)state;
    (void)params;
    (void)count;
}

// ---------------------------------------------------------------------------
// Key Encoder Stubs
// ---------------------------------------------------------------------------

size_t ghostty_key_encode(const ghostty_key_event_t *event,
                          const ghostty_key_config_t *config,
                          char *out,
                          size_t out_len) {
    // Stub: no-op
    (void)event;
    (void)config;
    (void)out;
    (void)out_len;
    return 0;
}

// ---------------------------------------------------------------------------
// OSC Parser Stubs
// ---------------------------------------------------------------------------

ghostty_osc_result_t ghostty_osc_parse(const char *payload, size_t payload_len) {
    ghostty_osc_result_t result;
    memset(&result, 0, sizeof(result));
    result.type = GHOSTTY_OSC_UNKNOWN;
    result.data = payload;
    result.data_len = payload_len;
    return result;
}

// ---------------------------------------------------------------------------
// VT Parser Stubs
// ---------------------------------------------------------------------------

struct ghostty_vt_parser {
    int state; // placeholder
};

ghostty_vt_parser_t *ghostty_vt_parser_create(void) {
    ghostty_vt_parser_t *p = calloc(1, sizeof(ghostty_vt_parser_t));
    return p;
}

void ghostty_vt_parser_destroy(ghostty_vt_parser_t *parser) {
    free(parser);
}

bool ghostty_vt_parser_feed(ghostty_vt_parser_t *parser,
                            uint8_t byte,
                            ghostty_vt_action_t *action) {
    // Stub: real implementation will come from libghostty-vt.
    (void)parser;
    (void)byte;
    (void)action;
    return false;
}
