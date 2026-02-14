// TODO: Implement local echo prediction for Mosh.
//
// Mosh's local echo prediction engine displays the predicted effect of
// user keystrokes immediately, without waiting for a server round-trip.
// When the server's actual response arrives, the prediction is replaced
// with the real output. This makes typing feel instant even on high-latency
// connections. The predictor tracks cursor position, character cells, and
// uses heuristics to decide when prediction is safe (e.g., it disables
// prediction inside password prompts or when the application switches to
// an alternate screen buffer).
