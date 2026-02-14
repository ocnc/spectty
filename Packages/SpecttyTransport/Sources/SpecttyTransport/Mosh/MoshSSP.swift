// TODO: Implement the State Synchronization Protocol (SSP) for Mosh.
//
// SSP is Mosh's core protocol layer. Rather than streaming bytes like SSH,
// SSP synchronizes the *state* of the terminal between client and server.
// Each side maintains a copy of the terminal state and periodically sends
// diffs. This allows the protocol to be robust against packet loss and
// network changes -- the latest state can always be reconstructed from
// the most recent diff plus the last acknowledged state.
