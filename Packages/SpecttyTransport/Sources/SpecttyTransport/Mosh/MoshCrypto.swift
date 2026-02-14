// TODO: Implement AES-128-OCB3 (Offset Codebook Mode) encryption for Mosh.
//
// Mosh uses AES-128-OCB3 as its authenticated encryption scheme. The 128-bit
// key is exchanged over the initial SSH session. Each datagram is encrypted
// and authenticated in a single pass with a unique nonce derived from the
// sequence number.
