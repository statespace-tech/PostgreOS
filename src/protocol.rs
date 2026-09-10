//! Length-delimited local protocol used by `pgos` and `pgosd`.

use std::io::{self, Read, Write};

use bincode::{Decode, Encode};
use thiserror::Error;

pub const VERSION: u16 = 13;
const MAX_FRAME_SIZE: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub struct Request {
    pub version: u16,
    pub volume: String,
    pub operation: Operation,
}

impl Request {
    #[must_use]
    pub fn new(volume: String, operation: Operation) -> Self {
        Self {
            version: VERSION,
            volume,
            operation,
        }
    }
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub enum Operation {
    ReadRange {
        path: String,
        offset: u64,
        length: u32,
    },
    TextStream {
        path: String,
        literals: Option<Vec<String>>,
        word: Option<String>,
        minimum_ascii_letters: Option<u32>,
    },
    GrepFile {
        path: String,
        pattern: String,
        line_number: bool,
    },
    List {
        path: String,
    },
    ListNames {
        path: String,
    },
    ListOutput {
        path: String,
        all: bool,
    },
    Stat {
        path: String,
    },
    Inode {
        id: i64,
    },
    Read {
        path: String,
    },
    ReadMany {
        paths: Vec<String>,
    },
    Cat {
        paths: Vec<String>,
    },
    Write {
        path: String,
        data: Vec<u8>,
    },
    WriteEntry {
        path: String,
        data: Vec<u8>,
    },
    Walk {
        path: String,
    },
    Find {
        root: String,
        name_pattern: Option<String>,
        kind: Option<i16>,
    },
    FindPaths {
        root: String,
        name_pattern: Option<String>,
        kind: Option<i16>,
    },
    FindOutput {
        root: String,
        name_pattern: Option<String>,
        kind: Option<i16>,
        path_prefix: String,
    },
    DiskUsage {
        path: String,
    },
    SearchLiteral {
        root: String,
        needle: String,
    },
    SearchLiteralFiles {
        root: String,
        needle: String,
    },
    GrepLiteralOutput {
        root: String,
        needle: String,
        line_number: bool,
        path_prefix: String,
    },
    GrepRegexOutput {
        root: String,
        pattern: String,
        line_number: bool,
        path_prefix: String,
        file_suffixes: Vec<String>,
    },
    Mkdir {
        path: String,
        parents: bool,
    },
    MkdirEntry {
        path: String,
        parents: bool,
    },
    SetTimes {
        path: String,
        atime: Timestamp,
        mtime: Timestamp,
    },
    MkdirMany {
        paths: Vec<String>,
        parents: bool,
    },
    Copy {
        source: String,
        destination: String,
        recursive: bool,
    },
    Move {
        source: String,
        destination: String,
    },
    Remove {
        path: String,
        recursive: bool,
    },
    RemoveMany {
        paths: Vec<String>,
        recursive: bool,
        force: bool,
    },
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub struct Response {
    pub version: u16,
    pub result: Result<Output, RemoteError>,
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub enum Output {
    SearchDone(bool),
    Entries(Vec<Entry>),
    Paths(Vec<String>),
    Names(Vec<String>),
    TextFiles(Vec<TextFile>),
    SearchOutput { data: Vec<u8>, matched: bool },
    Entry(Entry),
    Data(Vec<u8>),
    DataMany(Vec<Vec<u8>>),
    Count(i64),
    Unit,
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub struct TextFile {
    pub path: String,
    pub text: String,
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
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

#[derive(Debug, Clone, Copy, Encode, Decode, PartialEq, Eq)]
pub struct Timestamp {
    pub seconds: i64,
    pub nanoseconds: u32,
}

#[derive(Debug, Clone, Encode, Decode, PartialEq, Eq)]
pub struct RemoteError {
    pub message: String,
}

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("protocol I/O failed")]
    Io(#[from] io::Error),
    #[error("protocol frame is too large: {0} bytes")]
    FrameTooLarge(usize),
    #[error("could not encode protocol frame: {0}")]
    Encode(#[from] bincode::error::EncodeError),
    #[error("could not decode protocol frame: {0}")]
    Decode(#[from] bincode::error::DecodeError),
}

pub fn write_frame<T: Encode>(writer: &mut impl Write, value: &T) -> Result<(), ProtocolError> {
    let payload = bincode::encode_to_vec(value, bincode::config::standard())?;
    if payload.len() > MAX_FRAME_SIZE {
        return Err(ProtocolError::FrameTooLarge(payload.len()));
    }
    let length =
        u32::try_from(payload.len()).map_err(|_| ProtocolError::FrameTooLarge(payload.len()))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()?;
    Ok(())
}

pub fn read_frame<T: Decode<()>>(reader: &mut impl Read) -> Result<T, ProtocolError> {
    let mut length = [0_u8; 4];
    reader.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_FRAME_SIZE {
        return Err(ProtocolError::FrameTooLarge(length));
    }
    let mut payload = vec![0; length];
    reader.read_exact(&mut payload)?;
    let (value, consumed) = bincode::decode_from_slice(&payload, bincode::config::standard())?;
    if consumed != payload.len() {
        return Err(ProtocolError::Decode(
            bincode::error::DecodeError::OtherString("trailing bytes in frame".to_owned()),
        ));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{Operation, Request, read_frame, write_frame};

    #[test]
    fn request_round_trip() {
        let expected = Request::new(
            "development".to_owned(),
            Operation::Read {
                path: "/notes.txt".to_owned(),
            },
        );
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &expected).unwrap();
        assert_eq!(
            read_frame::<Request>(&mut bytes.as_slice()).unwrap(),
            expected
        );
    }
}
