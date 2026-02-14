// ghostty_vt.h — Stub header for libghostty-vt C API
// This will be replaced with the real headers when libghostty-vt is compiled.
// For now, we define the types and functions we expect to use.

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// SGR (Select Graphic Rendition) Parser
// ---------------------------------------------------------------------------

typedef struct {
    uint8_t r, g, b;
} ghostty_color_rgb_t;

typedef enum {
    GHOSTTY_COLOR_TYPE_NONE = 0,
    GHOSTTY_COLOR_TYPE_INDEXED = 1,
    GHOSTTY_COLOR_TYPE_RGB = 2,
    GHOSTTY_COLOR_TYPE_DEFAULT = 3,
} ghostty_color_type_t;

typedef struct {
    ghostty_color_type_t type;
    union {
        uint8_t index;      // For INDEXED
        ghostty_color_rgb_t rgb; // For RGB
    };
} ghostty_color_t;

typedef struct {
    ghostty_color_t fg;
    ghostty_color_t bg;
    bool bold;
    bool italic;
    bool underline;
    bool strikethrough;
    bool inverse;
    bool dim;
    bool hidden;
    bool blink;
} ghostty_sgr_state_t;

// Initialize an SGR state to defaults
void ghostty_sgr_init(ghostty_sgr_state_t *state);

// Parse an SGR sequence. `params` points to the numeric parameters
// (e.g., for "\e[1;31m", params = {1, 31}, count = 2).
// Updates `state` in-place.
void ghostty_sgr_parse(ghostty_sgr_state_t *state,
                       const uint16_t *params,
                       size_t count);

// ---------------------------------------------------------------------------
// Key Encoder
// ---------------------------------------------------------------------------

typedef enum {
    GHOSTTY_KEY_PROTOCOL_LEGACY = 0,
    GHOSTTY_KEY_PROTOCOL_KITTY = 1,
} ghostty_key_protocol_t;

typedef struct {
    uint32_t keycode;      // USB HID keycode
    uint32_t modifiers;    // Bitmask: 1=shift, 2=alt, 4=ctrl, 8=super
    bool key_down;         // true for press, false for release
    uint32_t codepoint;    // Unicode codepoint of the key, or 0
} ghostty_key_event_t;

typedef struct {
    bool application_cursor; // DECCKM mode
    bool application_keypad; // DECKPAM mode
    ghostty_key_protocol_t protocol;
} ghostty_key_config_t;

// Encode a key event into an escape sequence.
// Returns the number of bytes written to `out`, or 0 if no encoding.
// `out` must be at least `out_len` bytes.
size_t ghostty_key_encode(const ghostty_key_event_t *event,
                          const ghostty_key_config_t *config,
                          char *out,
                          size_t out_len);

// ---------------------------------------------------------------------------
// OSC (Operating System Command) Parser
// ---------------------------------------------------------------------------

typedef enum {
    GHOSTTY_OSC_SET_TITLE = 0,
    GHOSTTY_OSC_SET_ICON = 1,
    GHOSTTY_OSC_SET_TITLE_AND_ICON = 2,
    GHOSTTY_OSC_CLIPBOARD = 52,
    GHOSTTY_OSC_HYPERLINK = 8,
    GHOSTTY_OSC_COLOR_QUERY = 4,
    GHOSTTY_OSC_FG_COLOR = 10,
    GHOSTTY_OSC_BG_COLOR = 11,
    GHOSTTY_OSC_CURSOR_COLOR = 12,
    GHOSTTY_OSC_UNKNOWN = 255,
} ghostty_osc_type_t;

typedef struct {
    ghostty_osc_type_t type;
    const char *data;       // Pointer into the parsed data (not null-terminated)
    size_t data_len;
} ghostty_osc_result_t;

// Parse an OSC sequence payload (everything between OSC and ST).
// Returns the parsed result. `data` and `data_len` point into `payload`.
ghostty_osc_result_t ghostty_osc_parse(const char *payload, size_t payload_len);

// ---------------------------------------------------------------------------
// VT Parser (state machine for escape sequence detection)
// ---------------------------------------------------------------------------

typedef enum {
    GHOSTTY_VT_ACTION_PRINT = 0,
    GHOSTTY_VT_ACTION_EXECUTE = 1,      // C0 control
    GHOSTTY_VT_ACTION_CSI_DISPATCH = 2,
    GHOSTTY_VT_ACTION_ESC_DISPATCH = 3,
    GHOSTTY_VT_ACTION_OSC_END = 4,
    GHOSTTY_VT_ACTION_DCS_END = 5,
    GHOSTTY_VT_ACTION_APC_END = 6,
} ghostty_vt_action_type_t;

typedef struct {
    ghostty_vt_action_type_t type;

    // For PRINT: the codepoint
    uint32_t codepoint;

    // For EXECUTE: the C0 byte
    uint8_t control_byte;

    // For CSI_DISPATCH: final byte and collected parameters
    char csi_final;
    char csi_intermediate;  // Usually 0, or '?' for private modes, '!' etc.
    uint16_t csi_params[16];
    uint8_t csi_param_count;

    // For ESC_DISPATCH: the final byte and intermediate
    char esc_final;
    char esc_intermediate;

    // For OSC_END: payload
    const char *osc_payload;
    size_t osc_payload_len;
} ghostty_vt_action_t;

// Opaque VT parser state
typedef struct ghostty_vt_parser ghostty_vt_parser_t;

// Create/destroy a parser
ghostty_vt_parser_t *ghostty_vt_parser_create(void);
void ghostty_vt_parser_destroy(ghostty_vt_parser_t *parser);

// Feed a single byte. Returns true if an action was produced.
// If true, fills `action` with the result.
bool ghostty_vt_parser_feed(ghostty_vt_parser_t *parser,
                            uint8_t byte,
                            ghostty_vt_action_t *action);

#ifdef __cplusplus
}
#endif

#endif // GHOSTTY_VT_H
