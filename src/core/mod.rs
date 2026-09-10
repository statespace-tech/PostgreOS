//! Shared types and invariants for `PostgreOS` components.

pub mod path;
pub mod search;

/// Metadata returned by the public `pgos` SQL API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: i64,
    pub path: String,
    pub name: String,
    pub kind: i16,
    pub mode: i32,
    pub uid: i32,
    pub gid: i32,
    pub size: i64,
    pub generation: i64,
    pub atime_seconds: i64,
    pub atime_nanoseconds: u32,
    pub mtime_seconds: i64,
    pub mtime_nanoseconds: u32,
    pub ctime_seconds: i64,
    pub ctime_nanoseconds: u32,
}

impl Entry {
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        // These values are part of the versioned SQL API.
        match self.kind {
            1 => "file",
            2 => "directory",
            3 => "symlink",
            _ => "unknown",
        }
    }
}
