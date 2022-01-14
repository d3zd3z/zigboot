// SPDX-License-Identifier: Apache-2.0
//
// Zigboot configuration

// TODO: Can we derive this from the Zephyr configuration?

/// The swap-hash algorithm supports two different ways of storing the
/// status, each appropriate for different kinds of flash devices.
pub const StatusMode = enum {
    /// The InPlace status mode is similar to the existing way status
    /// is written.  This assumes that the underlying device's "write
    /// alignment" is fairly small (1-8) to medium (16-32), and works
    /// if the erase size is fairly large.  Data is partially written,
    /// leaving values unwritten (0xFF) that can be updated later.
    InPlace,

    /// The Paged status mode supports devices with larger write
    /// alignment (512 bytes) that also have a relatively small erase
    /// size (typically also 512 bytes).
    Paged,
};

/// What status mode are we building for.
pub const status: StatusMode = .Paged;

/// The trailer is built with a particular maximum device alignment.
/// For InPlace mode, we will support any devices with an alignment up
/// to this size.  This value is not meaningful in the Paged mode.
///
/// This is historically 8, which is needed to maintain compatibility
/// with the current magic values.
pub const max_device_alignment = 8;
