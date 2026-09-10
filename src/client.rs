//! Thread-safe client for the local `pgosd` Unix socket.

use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::{Mutex, PoisonError};

use crate::core::Entry;
use crate::protocol::{Operation, Output, ProtocolError, Request, Response, VERSION};
pub use crate::protocol::{TextFile, Timestamp};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ClientError {
    #[error("could not connect to pgosd socket {path:?}")]
    Connect {
        path: String,
        #[source]
        source: io::Error,
    },
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error("pgosd uses protocol version {0}, but this client uses {VERSION}")]
    Version(u16),
    #[error("pgosd request failed: {0}")]
    Remote(String),
    #[error("pgosd returned an unexpected response")]
    UnexpectedResponse,
    #[error("pgosd client lock is poisoned")]
    Poisoned,
}

impl<T> From<PoisonError<T>> for ClientError {
    fn from(_: PoisonError<T>) -> Self {
        Self::Poisoned
    }
}

/// A persistent connection to one daemon and one selected volume.
pub struct Client {
    stream: Mutex<UnixStream>,
    volume: String,
}

impl Client {
    pub fn read_range(&self, path: &str, offset: u64, length: u32) -> Result<Vec<u8>, ClientError> {
        match self.call(Operation::ReadRange {
            path: path.to_owned(),
            offset,
            length,
        })? {
            Output::Data(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn grep_file(
        &self,
        path: &str,
        pattern: &str,
        line_number: bool,
        output: &mut impl io::Write,
    ) -> Result<bool, ClientError> {
        self.stream_output(
            Operation::GrepFile {
                path: path.to_owned(),
                pattern: pattern.to_owned(),
                line_number,
            },
            output,
        )
    }

    pub fn text_stream(
        &self,
        path: &str,
        literals: Option<Vec<String>>,
        word: Option<String>,
        minimum_ascii_letters: Option<u32>,
        output: &mut impl io::Write,
    ) -> Result<(), ClientError> {
        self.stream_output(
            Operation::TextStream {
                path: path.to_owned(),
                literals,
                word,
                minimum_ascii_letters,
            },
            output,
        )?;
        Ok(())
    }

    fn stream_output(
        &self,
        operation: Operation,
        output: &mut impl io::Write,
    ) -> Result<bool, ClientError> {
        let mut stream = self.stream.lock()?;
        let request = Request::new(self.volume.clone(), operation);
        crate::protocol::write_frame(&mut *stream, &request)?;
        loop {
            let response: Response = crate::protocol::read_frame(&mut *stream)?;
            if response.version != VERSION {
                return Err(ClientError::Version(response.version));
            }
            match response
                .result
                .map_err(|error| ClientError::Remote(error.message))?
            {
                Output::Data(data) => {
                    if let Err(error) = output.write_all(&data) {
                        // A partial response cannot be reused as the next
                        // request's response after a broken output pipe.
                        let _ = stream.shutdown(std::net::Shutdown::Both);
                        return Err(ProtocolError::Io(error).into());
                    }
                }
                Output::SearchDone(matched) => return Ok(matched),
                _ => return Err(ClientError::UnexpectedResponse),
            }
        }
    }

    pub fn connect(path: &Path, volume: impl Into<String>) -> Result<Self, ClientError> {
        let stream = UnixStream::connect(path).map_err(|source| ClientError::Connect {
            path: path.display().to_string(),
            source,
        })?;
        Ok(Self {
            stream: Mutex::new(stream),
            volume: volume.into(),
        })
    }

    fn call(&self, operation: Operation) -> Result<Output, ClientError> {
        // One connection carries ordered request/response pairs. The mutex also
        // lets concurrent FUSE callbacks safely share this persistent socket.
        let mut stream = self.stream.lock()?;
        crate::protocol::write_frame(&mut *stream, &Request::new(self.volume.clone(), operation))?;
        let response: Response = crate::protocol::read_frame(&mut *stream)?;
        if response.version != VERSION {
            return Err(ClientError::Version(response.version));
        }
        response
            .result
            .map_err(|error| ClientError::Remote(error.message))
    }

    pub fn list(&self, path: &str) -> Result<Vec<Entry>, ClientError> {
        self.entries(Operation::List {
            path: path.to_owned(),
        })
    }

    pub fn list_names(&self, path: &str) -> Result<Vec<String>, ClientError> {
        match self.call(Operation::ListNames {
            path: path.to_owned(),
        })? {
            Output::Names(names) => Ok(names),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn list_output(&self, path: &str, all: bool) -> Result<Vec<u8>, ClientError> {
        match self.call(Operation::ListOutput {
            path: path.to_owned(),
            all,
        })? {
            Output::Data(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn walk(&self, path: &str) -> Result<Vec<Entry>, ClientError> {
        self.entries(Operation::Walk {
            path: path.to_owned(),
        })
    }

    pub fn find(
        &self,
        root: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
    ) -> Result<Vec<Entry>, ClientError> {
        self.entries(Operation::Find {
            root: root.to_owned(),
            name_pattern: name_pattern.map(str::to_owned),
            kind,
        })
    }

    pub fn find_paths(
        &self,
        root: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
    ) -> Result<Vec<String>, ClientError> {
        match self.call(Operation::FindPaths {
            root: root.to_owned(),
            name_pattern: name_pattern.map(str::to_owned),
            kind,
        })? {
            Output::Paths(paths) => Ok(paths),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn find_output(
        &self,
        root: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
        path_prefix: &str,
    ) -> Result<Vec<u8>, ClientError> {
        match self.call(Operation::FindOutput {
            root: root.to_owned(),
            name_pattern: name_pattern.map(str::to_owned),
            kind,
            path_prefix: path_prefix.to_owned(),
        })? {
            Output::Data(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn disk_usage(&self, path: &str) -> Result<i64, ClientError> {
        self.count(Operation::DiskUsage {
            path: path.to_owned(),
        })
    }

    pub fn search_literal(&self, root: &str, needle: &str) -> Result<Vec<String>, ClientError> {
        match self.call(Operation::SearchLiteral {
            root: root.to_owned(),
            needle: needle.to_owned(),
        })? {
            Output::Paths(paths) => Ok(paths),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn search_literal_files(
        &self,
        root: &str,
        needle: &str,
    ) -> Result<Vec<TextFile>, ClientError> {
        match self.call(Operation::SearchLiteralFiles {
            root: root.to_owned(),
            needle: needle.to_owned(),
        })? {
            Output::TextFiles(files) => Ok(files),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn grep_literal_output(
        &self,
        root: &str,
        needle: &str,
        line_number: bool,
        path_prefix: &str,
    ) -> Result<(Vec<u8>, bool), ClientError> {
        match self.call(Operation::GrepLiteralOutput {
            root: root.to_owned(),
            needle: needle.to_owned(),
            line_number,
            path_prefix: path_prefix.to_owned(),
        })? {
            Output::SearchOutput { data, matched } => Ok((data, matched)),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn grep_regex_output(
        &self,
        root: &str,
        pattern: &str,
        line_number: bool,
        path_prefix: &str,
        file_suffixes: &[String],
        output: &mut impl io::Write,
    ) -> Result<bool, ClientError> {
        self.stream_output(
            Operation::GrepRegexOutput {
                root: root.to_owned(),
                pattern: pattern.to_owned(),
                line_number,
                path_prefix: path_prefix.to_owned(),
                file_suffixes: file_suffixes.to_vec(),
            },
            output,
        )
    }

    fn entries(&self, operation: Operation) -> Result<Vec<Entry>, ClientError> {
        match self.call(operation)? {
            Output::Entries(entries) => Ok(entries.into_iter().map(core_entry).collect()),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn stat(&self, path: &str) -> Result<Entry, ClientError> {
        self.entry(Operation::Stat {
            path: path.to_owned(),
        })
    }

    pub fn inode(&self, id: i64) -> Result<Entry, ClientError> {
        self.entry(Operation::Inode { id })
    }

    fn entry(&self, operation: Operation) -> Result<Entry, ClientError> {
        match self.call(operation)? {
            Output::Entry(entry) => Ok(core_entry(entry)),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn read(&self, path: &str) -> Result<Vec<u8>, ClientError> {
        match self.call(Operation::Read {
            path: path.to_owned(),
        })? {
            Output::Data(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn read_many(&self, paths: &[String]) -> Result<Vec<Vec<u8>>, ClientError> {
        match self.call(Operation::ReadMany {
            paths: paths.to_vec(),
        })? {
            Output::DataMany(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn cat(&self, paths: &[String]) -> Result<Vec<u8>, ClientError> {
        match self.call(Operation::Cat {
            paths: paths.to_vec(),
        })? {
            Output::Data(data) => Ok(data),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn write(&self, path: &str, data: &[u8]) -> Result<i64, ClientError> {
        self.count(Operation::Write {
            path: path.to_owned(),
            data: data.to_vec(),
        })
    }

    pub fn write_entry(&self, path: &str, data: &[u8]) -> Result<Entry, ClientError> {
        self.entry(Operation::WriteEntry {
            path: path.to_owned(),
            data: data.to_vec(),
        })
    }

    pub fn mkdir(&self, path: &str, parents: bool) -> Result<(), ClientError> {
        match self.call(Operation::Mkdir {
            path: path.to_owned(),
            parents,
        })? {
            Output::Unit => Ok(()),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn mkdir_entry(&self, path: &str, parents: bool) -> Result<Entry, ClientError> {
        self.entry(Operation::MkdirEntry {
            path: path.to_owned(),
            parents,
        })
    }

    pub fn set_times(
        &self,
        path: &str,
        atime: Timestamp,
        mtime: Timestamp,
    ) -> Result<Entry, ClientError> {
        self.entry(Operation::SetTimes {
            path: path.to_owned(),
            atime,
            mtime,
        })
    }

    pub fn mkdir_many(&self, paths: &[String], parents: bool) -> Result<(), ClientError> {
        match self.call(Operation::MkdirMany {
            paths: paths.to_vec(),
            parents,
        })? {
            Output::Unit => Ok(()),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }

    pub fn copy(
        &self,
        source: &str,
        destination: &str,
        recursive: bool,
    ) -> Result<i64, ClientError> {
        self.count(Operation::Copy {
            source: source.to_owned(),
            destination: destination.to_owned(),
            recursive,
        })
    }

    pub fn move_path(&self, source: &str, destination: &str) -> Result<i64, ClientError> {
        self.count(Operation::Move {
            source: source.to_owned(),
            destination: destination.to_owned(),
        })
    }

    pub fn remove(&self, path: &str, recursive: bool) -> Result<i64, ClientError> {
        self.count(Operation::Remove {
            path: path.to_owned(),
            recursive,
        })
    }

    pub fn remove_many(
        &self,
        paths: &[String],
        recursive: bool,
        force: bool,
    ) -> Result<i64, ClientError> {
        self.count(Operation::RemoveMany {
            paths: paths.to_vec(),
            recursive,
            force,
        })
    }

    fn count(&self, operation: Operation) -> Result<i64, ClientError> {
        match self.call(operation)? {
            Output::Count(count) => Ok(count),
            _ => Err(ClientError::UnexpectedResponse),
        }
    }
}

fn core_entry(entry: crate::protocol::Entry) -> Entry {
    Entry {
        id: entry.id,
        path: entry.path,
        name: entry.name,
        kind: entry.kind,
        mode: entry.mode,
        uid: entry.uid,
        gid: entry.gid,
        size: entry.size,
        generation: entry.generation,
        atime_seconds: entry.atime_seconds,
        atime_nanoseconds: entry.atime_nanoseconds,
        mtime_seconds: entry.mtime_seconds,
        mtime_nanoseconds: entry.mtime_nanoseconds,
        ctime_seconds: entry.ctime_seconds,
        ctime_nanoseconds: entry.ctime_nanoseconds,
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixListener;
    use std::thread;

    use crate::protocol::{Output, Request, Response, VERSION};
    use tempfile::TempDir;

    use super::Client;

    #[test]
    fn reuses_one_connection_for_multiple_requests() {
        let directory = TempDir::new().unwrap();
        let socket = directory.path().join("pgosd.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let first: Request = crate::protocol::read_frame(&mut stream).unwrap();
            assert_eq!(first.volume, "development");
            crate::protocol::write_frame(
                &mut stream,
                &Response {
                    version: VERSION,
                    result: Ok(Output::Entries(Vec::new())),
                },
            )
            .unwrap();
            let second: Request = crate::protocol::read_frame(&mut stream).unwrap();
            assert_eq!(second.volume, "development");
            crate::protocol::write_frame(
                &mut stream,
                &Response {
                    version: VERSION,
                    result: Ok(Output::Data(b"hello".to_vec())),
                },
            )
            .unwrap();
        });

        let client = Client::connect(&socket, "development").unwrap();
        assert!(client.list("/").unwrap().is_empty());
        assert_eq!(client.read("/hello.txt").unwrap(), b"hello");
        server.join().unwrap();
    }
}
