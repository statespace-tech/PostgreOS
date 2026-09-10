//! Long-lived local broker for PostgreSQL-backed file operations.

use std::collections::HashMap;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::{FileTypeExt as _, PermissionsExt as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::Parser;
use postgreos::core::{
    Entry,
    search::{literal_output, required_literals},
};
use postgreos::postgres::Database;
use postgreos::protocol::{Operation, Output, RemoteError, Request, Response, TextFile, VERSION};
use uuid::Uuid;

const VOLUME_CACHE_TTL: Duration = Duration::from_secs(30);
const STREAM_FRAME_BYTES: usize = 256 * 1024;

#[derive(Parser)]
#[command(name = "pgosd", version, about = "PostgreOS local database daemon")]
struct Args {
    #[arg(
        long,
        env = "PGOS_DATABASE_URL",
        default_value = "postgresql:///pgos_dev"
    )]
    database_url: String,
    #[arg(long, env = "PGOS_SOCKET", default_value = "/tmp/pgosd.sock")]
    socket: PathBuf,
}

struct CachedVolume {
    id: Uuid,
    resolved_at: Instant,
}

struct State {
    database: Database,
    volumes: RwLock<HashMap<String, CachedVolume>>,
}

impl State {
    fn resolve_volume(&self, name: &str) -> Result<Uuid> {
        if let Some(id) = self
            .volumes
            .read()
            .map_err(|_| anyhow::anyhow!("volume cache lock is poisoned"))?
            .get(name)
            .filter(|entry| entry.resolved_at.elapsed() < VOLUME_CACHE_TTL)
            .map(|entry| entry.id)
        {
            return Ok(id);
        }
        let id = self.database.resolve_volume(name)?;
        self.volumes
            .write()
            .map_err(|_| anyhow::anyhow!("volume cache lock is poisoned"))?
            .insert(
                name.to_owned(),
                CachedVolume {
                    id,
                    resolved_at: Instant::now(),
                },
            );
        Ok(id)
    }
}

struct SocketGuard(PathBuf);

struct ResponseBuffer<'a> {
    stream: &'a mut UnixStream,
    data: Vec<u8>,
}

impl<'a> ResponseBuffer<'a> {
    fn new(stream: &'a mut UnixStream) -> Self {
        Self {
            stream,
            data: Vec::with_capacity(STREAM_FRAME_BYTES),
        }
    }

    fn write(&mut self, mut data: &[u8]) -> Result<()> {
        while !data.is_empty() {
            let available = STREAM_FRAME_BYTES - self.data.len();
            let length = available.min(data.len());
            self.data.extend_from_slice(&data[..length]);
            data = &data[length..];
            if self.data.len() == STREAM_FRAME_BYTES {
                self.flush()?;
            }
        }
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        if self.data.is_empty() {
            return Ok(());
        }
        postgreos::protocol::write_frame(
            self.stream,
            &Response {
                version: VERSION,
                result: Ok(Output::Data(std::mem::take(&mut self.data))),
            },
        )?;
        self.data = Vec::with_capacity(STREAM_FRAME_BYTES);
        Ok(())
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pgosd: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let args = Args::parse();
    let database = Database::connect_pooled(&args.database_url)?;
    // Acquire one connection now so startup fails before the socket is made
    // visible when PostgreSQL is unavailable.
    database
        .volumes()
        .context("could not validate PostgreSQL")?;
    prepare_socket_path(&args.socket)?;
    let listener = UnixListener::bind(&args.socket)
        .with_context(|| format!("could not bind socket {}", args.socket.display()))?;
    fs::set_permissions(&args.socket, fs::Permissions::from_mode(0o600))?;
    let _socket_guard = SocketGuard(args.socket.clone());
    let state = Arc::new(State {
        database,
        volumes: RwLock::new(HashMap::new()),
    });

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = Arc::clone(&state);
                thread::spawn(move || {
                    if let Err(error) = serve_connection(&state, stream) {
                        eprintln!("pgosd: client connection failed: {error:#}");
                    }
                });
            }
            Err(error) => eprintln!("pgosd: could not accept client: {error}"),
        }
    }
    Ok(())
}

fn prepare_socket_path(path: &Path) -> Result<()> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if !metadata.file_type().is_socket() {
        bail!("refusing to replace non-socket path {}", path.display());
    }
    match UnixStream::connect(path) {
        Ok(_) => bail!("a pgosd process is already listening at {}", path.display()),
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::ConnectionRefused | ErrorKind::NotFound
            ) =>
        {
            fs::remove_file(path)
                .with_context(|| format!("could not remove stale socket {}", path.display()))?;
            Ok(())
        }
        Err(error) => Err(error)
            .with_context(|| format!("could not inspect existing socket {}", path.display())),
    }
}

#[allow(clippy::too_many_lines)]
fn serve_connection(state: &State, mut stream: UnixStream) -> Result<()> {
    loop {
        let request: Request = match postgreos::protocol::read_frame(&mut stream) {
            Ok(request) => request,
            Err(postgreos::protocol::ProtocolError::Io(error))
                if matches!(
                    error.kind(),
                    ErrorKind::UnexpectedEof | ErrorKind::ConnectionReset
                ) =>
            {
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };
        if request.version == VERSION
            && matches!(
                request.operation,
                Operation::GrepFile { .. }
                    | Operation::TextStream { .. }
                    | Operation::GrepRegexOutput { .. }
            )
        {
            let result = (|| -> Result<Output> {
                let volume = state.resolve_volume(&request.volume)?;
                let mut buffer = ResponseBuffer::new(&mut stream);
                let mut send = |data: &[u8]| buffer.write(data);
                let matched = match &request.operation {
                    Operation::GrepFile {
                        path,
                        pattern,
                        line_number,
                    } => {
                        state
                            .database
                            .grep_file(volume, path, pattern, *line_number, &mut send)?
                    }
                    Operation::TextStream {
                        path,
                        literals,
                        word,
                        minimum_ascii_letters,
                    } => {
                        state.database.candidate_word_text(
                            volume,
                            path,
                            literals.as_deref(),
                            word.as_deref(),
                            *minimum_ascii_letters,
                            &mut send,
                        )?;
                        false
                    }
                    Operation::GrepRegexOutput {
                        root,
                        pattern,
                        line_number,
                        path_prefix,
                        file_suffixes,
                    } => grep_regex_output(
                        &state.database,
                        volume,
                        root,
                        pattern,
                        *line_number,
                        path_prefix,
                        file_suffixes,
                        &mut send,
                    )?,
                    _ => unreachable!(),
                };
                buffer.flush()?;
                Ok(Output::SearchDone(matched))
            })()
            .map_err(|error| RemoteError {
                message: format!("{error:#}"),
            });
            postgreos::protocol::write_frame(
                &mut stream,
                &Response {
                    version: VERSION,
                    result,
                },
            )?;
            continue;
        }
        let result = if request.version == VERSION {
            handle_request(state, request).map_err(|error| RemoteError {
                message: format!("{error:#}"),
            })
        } else {
            Err(RemoteError {
                message: format!(
                    "unsupported protocol version {}; server uses {VERSION}",
                    request.version
                ),
            })
        };
        postgreos::protocol::write_frame(
            &mut stream,
            &Response {
                version: VERSION,
                result,
            },
        )?;
    }
}

// Keep the protocol dispatch exhaustive and in one place.
#[allow(clippy::too_many_lines)]
fn handle_request(state: &State, request: Request) -> Result<Output> {
    let volume = state.resolve_volume(&request.volume)?;
    let database = &state.database;
    Ok(match request.operation {
        Operation::ReadRange {
            path,
            offset,
            length,
        } => Output::Data(database.read_range(volume, &path, offset, length)?),
        Operation::GrepFile { .. }
        | Operation::TextStream { .. }
        | Operation::GrepRegexOutput { .. } => {
            anyhow::bail!("streaming operation requires streaming dispatch")
        }
        Operation::List { path } => Output::Entries(
            database
                .list(volume, &path)?
                .into_iter()
                .map(protocol_entry)
                .collect(),
        ),
        Operation::ListNames { path } => Output::Names(database.list_names(volume, &path)?),
        Operation::ListOutput { path, all } => {
            Output::Data(database.list_output(volume, &path, all)?)
        }
        Operation::Stat { path } => Output::Entry(protocol_entry(database.stat(volume, &path)?)),
        Operation::Inode { id } => Output::Entry(protocol_entry(database.inode(volume, id)?)),
        Operation::Read { path } => Output::Data(database.read(volume, &path)?),
        Operation::ReadMany { paths } => Output::DataMany(database.read_many(volume, &paths)?),
        Operation::Cat { paths } => Output::Data(database.cat(volume, &paths)?),
        Operation::Write { path, data } => Output::Count(database.write(volume, &path, &data)?),
        Operation::WriteEntry { path, data } => {
            Output::Entry(protocol_entry(database.write_entry(volume, &path, &data)?))
        }
        Operation::Walk { path } => Output::Entries(
            database
                .walk(volume, &path)?
                .into_iter()
                .map(protocol_entry)
                .collect(),
        ),
        Operation::Find {
            root,
            name_pattern,
            kind,
        } => Output::Entries(
            database
                .find(volume, &root, name_pattern.as_deref(), kind)?
                .into_iter()
                .map(protocol_entry)
                .collect(),
        ),
        Operation::FindPaths {
            root,
            name_pattern,
            kind,
        } => Output::Paths(database.find_paths(volume, &root, name_pattern.as_deref(), kind)?),
        Operation::FindOutput {
            root,
            name_pattern,
            kind,
            path_prefix,
        } => Output::Data(database.find_output(
            volume,
            &root,
            name_pattern.as_deref(),
            kind,
            &path_prefix,
        )?),
        Operation::DiskUsage { path } => Output::Count(database.disk_usage(volume, &path)?),
        Operation::SearchLiteral { root, needle } => {
            Output::Paths(database.search_literal(volume, &root, &needle)?)
        }
        Operation::SearchLiteralFiles { root, needle } => {
            search_literal_files(database, volume, &root, &needle)?
        }
        Operation::GrepLiteralOutput {
            root,
            needle,
            line_number,
            path_prefix,
        } => grep_literal_output(database, volume, &root, &needle, line_number, &path_prefix)?,
        Operation::Mkdir { path, parents } => {
            database.mkdir(volume, &path, parents)?;
            Output::Unit
        }
        Operation::MkdirEntry { path, parents } => Output::Entry(protocol_entry(
            database.mkdir_entry(volume, &path, parents)?,
        )),
        Operation::SetTimes { path, atime, mtime } => {
            Output::Entry(protocol_entry(database.set_times(
                volume,
                &path,
                atime.seconds,
                atime.nanoseconds,
                mtime.seconds,
                mtime.nanoseconds,
            )?))
        }
        Operation::MkdirMany { paths, parents } => {
            database.mkdir_many(volume, &paths, parents)?;
            Output::Unit
        }
        Operation::Copy {
            source,
            destination,
            recursive,
        } => Output::Count(database.copy(volume, &source, &destination, recursive)?),
        Operation::Move {
            source,
            destination,
        } => Output::Count(database.move_path(volume, &source, &destination)?),
        Operation::Remove { path, recursive } => {
            Output::Count(database.remove(volume, &path, recursive)?)
        }
        Operation::RemoveMany {
            paths,
            recursive,
            force,
        } => Output::Count(database.remove_many(volume, &paths, recursive, force)?),
    })
}

fn grep_literal_output(
    database: &Database,
    volume: Uuid,
    root: &str,
    needle: &str,
    line_number: bool,
    path_prefix: &str,
) -> Result<Output> {
    let files = database.search_literal_files(volume, root, needle)?;
    let (data, matched) = literal_output(
        files
            .iter()
            .map(|file| (file.path.as_str(), file.text.as_str())),
        needle,
        line_number,
        path_prefix,
    );
    Ok(Output::SearchOutput { data, matched })
}

#[allow(clippy::too_many_arguments)]
fn grep_regex_output(
    database: &Database,
    volume: Uuid,
    root: &str,
    pattern: &str,
    line_number: bool,
    path_prefix: &str,
    file_suffixes: &[String],
    mut send: impl FnMut(&[u8]) -> Result<()>,
) -> Result<bool> {
    let literals = required_literals(pattern);
    let mut matcher = postgreos::core::search::BlockMatcher::new(pattern, line_number)?;
    let mut found_any = false;
    let mut consume = |path: &str, first_line: i64, body: &str| {
        let prefix = format!("{path_prefix}{path}:");
        let (block_output, found) = matcher.search_prefixed(first_line, body, prefix.as_bytes())?;
        for frame in block_output.chunks(64 * 1024) {
            send(frame)?;
        }
        found_any |= found;
        Ok(())
    };
    database.candidate_blocks(
        volume,
        root,
        literals.as_deref(),
        file_suffixes,
        &mut consume,
    )?;
    Ok(found_any)
}

fn search_literal_files(
    database: &Database,
    volume: Uuid,
    root: &str,
    needle: &str,
) -> Result<Output> {
    Ok(Output::TextFiles(
        database
            .search_literal_files(volume, root, needle)?
            .into_iter()
            .map(|file| TextFile {
                path: file.path,
                text: file.text,
            })
            .collect(),
    ))
}

fn protocol_entry(entry: Entry) -> postgreos::protocol::Entry {
    postgreos::protocol::Entry {
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
