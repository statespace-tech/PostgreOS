//! Linux filesystem adapter for a `PostgreOS` volume.

use std::process::ExitCode;

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::ffi::OsStr;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Mutex, RwLock};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use anyhow::{Context, Result, bail};
    use clap::Parser;
    use fuser::{
        BsdFileFlags, Config, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags,
        Generation, INodeNo, LockOwner, MountOption, OpenFlags, RenameFlags, ReplyAttr,
        ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyWrite,
        Request, TimeOrNow, WriteFlags,
    };
    use postgreos::client::{Client, Timestamp};
    use postgreos::core::Entry;

    // Keep kernel metadata caching brief because other clients can change the
    // same remote PostgreSQL volume without notifying this mount.
    const TTL: Duration = Duration::from_millis(250);

    #[derive(Parser)]
    #[command(name = "pgos-mount", about = "Mount a PostgreOS volume")]
    struct Args {
        #[arg(long, env = "PGOS_SOCKET", default_value = "/tmp/pgosd.sock")]
        socket: PathBuf,
        #[arg(long, env = "PGOS_VOLUME", default_value = "development")]
        volume: String,
        #[arg(long)]
        read_only: bool,
        mountpoint: PathBuf,
    }

    pub fn run() -> Result<()> {
        let args = Args::parse();
        let client = Client::connect(&args.socket, &args.volume)?;
        client.stat("/").context("volume root is missing")?;

        let mut config = Config::default();
        config.n_threads = Some(8);
        config.clone_fd = true;
        config.mount_options.extend([
            MountOption::FSName(format!("postgresql-os:{}", args.volume)),
            MountOption::Subtype("postgresql-os".to_owned()),
            MountOption::DefaultPermissions,
            MountOption::NoDev,
            MountOption::NoSuid,
            if args.read_only {
                MountOption::RO
            } else {
                MountOption::RW
            },
        ]);

        let filesystem = PostgreOsFilesystem::new(client);
        fuser::mount(filesystem, &args.mountpoint, &config)
            .with_context(|| format!("could not mount {}", args.mountpoint.display()))?;
        Ok(())
    }

    struct PostgreOsFilesystem {
        client: Client,
        inode_paths: RwLock<HashMap<INodeNo, String>>,
        open_files: Mutex<HashMap<FileHandle, String>>,
        next_handle: AtomicU64,
    }

    impl PostgreOsFilesystem {
        fn new(client: Client) -> Self {
            Self {
                client,
                inode_paths: RwLock::new(HashMap::from([(INodeNo::ROOT, "/".to_owned())])),
                open_files: Mutex::new(HashMap::new()),
                next_handle: AtomicU64::new(1),
            }
        }

        fn remember(&self, entry: &Entry) {
            if let Ok(mut paths) = self.inode_paths.write() {
                paths.insert(Self::inode(entry), entry.path.clone());
            }
        }

        fn entry(&self, inode: INodeNo) -> Result<Entry> {
            let entry = if inode == INodeNo::ROOT {
                self.client.stat("/").map_err(anyhow::Error::from)
            } else {
                // FUSE reserves inode 1 for the root. Shift database IDs so no
                // database row can collide with it.
                let id = i64::try_from(u64::from(inode).saturating_sub(2))?;
                self.client.inode(id).map_err(anyhow::Error::from)
            }?;
            self.remember(&entry);
            Ok(entry)
        }

        fn inode_path(&self, inode: INodeNo) -> Result<String> {
            if let Ok(paths) = self.inode_paths.read()
                && let Some(path) = paths.get(&inode)
            {
                return Ok(path.clone());
            }
            Ok(self.entry(inode)?.path)
        }

        fn open_path(&self, handle: FileHandle, inode: INodeNo) -> Result<String> {
            if let Ok(files) = self.open_files.lock()
                && let Some(path) = files.get(&handle)
            {
                return Ok(path.clone());
            }
            self.inode_path(inode)
        }

        fn allocate_handle(&self, path: String) -> Result<FileHandle> {
            let handle = FileHandle(self.next_handle.fetch_add(1, Ordering::Relaxed));
            self.open_files
                .lock()
                .map_err(|_| anyhow::anyhow!("open-file table is poisoned"))?
                .insert(handle, path);
            Ok(handle)
        }

        fn inode(entry: &Entry) -> INodeNo {
            if entry.path == "/" {
                INodeNo::ROOT
            } else {
                INodeNo(u64::try_from(entry.id).unwrap_or(0).saturating_add(2))
            }
        }

        fn kind(entry: &Entry) -> FileType {
            match entry.kind {
                2 => FileType::Directory,
                3 => FileType::Symlink,
                _ => FileType::RegularFile,
            }
        }

        fn generation(entry: &Entry) -> Generation {
            Generation(u64::try_from(entry.generation).unwrap_or(0))
        }

        fn attr(entry: &Entry) -> FileAttr {
            let size = u64::try_from(entry.size).unwrap_or(0);
            FileAttr {
                ino: Self::inode(entry),
                size,
                blocks: size.div_ceil(512),
                atime: Self::system_time(entry.atime_seconds, entry.atime_nanoseconds),
                mtime: Self::system_time(entry.mtime_seconds, entry.mtime_nanoseconds),
                ctime: Self::system_time(entry.ctime_seconds, entry.ctime_nanoseconds),
                crtime: UNIX_EPOCH,
                kind: Self::kind(entry),
                perm: u16::try_from(entry.mode & 0o7777).unwrap_or(0),
                nlink: if entry.kind == 2 { 2 } else { 1 },
                uid: u32::try_from(entry.uid).unwrap_or(0),
                gid: u32::try_from(entry.gid).unwrap_or(0),
                rdev: 0,
                blksize: 4096,
                flags: 0,
            }
        }

        fn system_time(seconds: i64, nanoseconds: u32) -> SystemTime {
            if seconds >= 0 {
                UNIX_EPOCH + Duration::new(seconds.unsigned_abs(), nanoseconds)
            } else {
                UNIX_EPOCH - Duration::new(seconds.unsigned_abs(), nanoseconds)
            }
        }

        fn timestamp(value: SystemTime) -> Result<Timestamp> {
            let duration = value
                .duration_since(UNIX_EPOCH)
                .context("timestamps before the Unix epoch are not supported")?;
            Ok(Timestamp {
                seconds: i64::try_from(duration.as_secs())?,
                nanoseconds: duration.subsec_nanos(),
            })
        }

        fn child_path(&self, parent: INodeNo, name: &OsStr) -> Result<String> {
            let name = name
                .to_str()
                .context("the prototype supports UTF-8 names only")?;
            if name.is_empty() || name == "." || name == ".." || name.contains('/') {
                bail!("invalid directory entry name");
            }
            let parent = self.inode_path(parent)?;
            Ok(if parent == "/" {
                format!("/{name}")
            } else {
                format!("{parent}/{name}")
            })
        }

        fn parent_inode(&self, entry: &Entry) -> INodeNo {
            let Some((parent, _)) = entry.path.rsplit_once('/') else {
                return INodeNo::ROOT;
            };
            let parent = if parent.is_empty() { "/" } else { parent };
            self.client
                .stat(parent)
                .map_or(INodeNo::ROOT, |entry| Self::inode(&entry))
        }
    }

    impl Filesystem for PostgreOsFilesystem {
        fn lookup(&self, _request: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
            let result = self
                .child_path(parent, name)
                .and_then(|path| self.client.stat(&path).map_err(Into::into));
            match result {
                Ok(entry) => {
                    self.remember(&entry);
                    reply.entry(&TTL, &Self::attr(&entry), Self::generation(&entry));
                }
                Err(_) => reply.error(Errno::ENOENT),
            }
        }

        fn getattr(
            &self,
            _request: &Request,
            inode: INodeNo,
            _handle: Option<FileHandle>,
            reply: ReplyAttr,
        ) {
            match self.entry(inode) {
                Ok(entry) => reply.attr(&TTL, &Self::attr(&entry)),
                Err(_) => reply.error(Errno::ENOENT),
            }
        }

        fn setattr(
            &self,
            _request: &Request,
            inode: INodeNo,
            mode: Option<u32>,
            uid: Option<u32>,
            gid: Option<u32>,
            size: Option<u64>,
            atime: Option<TimeOrNow>,
            mtime: Option<TimeOrNow>,
            ctime: Option<SystemTime>,
            _handle: Option<FileHandle>,
            creation_time: Option<SystemTime>,
            chgtime: Option<SystemTime>,
            bkuptime: Option<SystemTime>,
            flags: Option<BsdFileFlags>,
            reply: ReplyAttr,
        ) {
            // The first metadata write path implements the operation used by
            // GNU touch. Other setattr fields need their own SQL semantics.
            if mode.is_some()
                || uid.is_some()
                || gid.is_some()
                || size.is_some()
                || ctime.is_some()
                || creation_time.is_some()
                || chgtime.is_some()
                || bkuptime.is_some()
                || flags.is_some()
            {
                reply.error(Errno::ENOSYS);
                return;
            }

            let now = SystemTime::now();
            let result = self.entry(inode).and_then(|entry| {
                let existing_access_time =
                    Self::system_time(entry.atime_seconds, entry.atime_nanoseconds);
                let existing_modification_time =
                    Self::system_time(entry.mtime_seconds, entry.mtime_nanoseconds);
                let atime = match atime {
                    Some(TimeOrNow::SpecificTime(value)) => value,
                    Some(TimeOrNow::Now) => now,
                    None => existing_access_time,
                };
                let mtime = match mtime {
                    Some(TimeOrNow::SpecificTime(value)) => value,
                    Some(TimeOrNow::Now) => now,
                    None => existing_modification_time,
                };
                Ok(self.client.set_times(
                    &entry.path,
                    Self::timestamp(atime)?,
                    Self::timestamp(mtime)?,
                )?)
            });
            match result {
                Ok(entry) => {
                    self.remember(&entry);
                    reply.attr(&TTL, &Self::attr(&entry));
                }
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn open(&self, _request: &Request, inode: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
            let result = self.entry(inode).and_then(|entry| {
                if entry.kind != 1 {
                    bail!("not a regular file");
                }
                if flags.0 & libc::O_TRUNC != 0 {
                    self.client.write(&entry.path, &[])?;
                }
                self.allocate_handle(entry.path)
            });
            match result {
                Ok(handle) => reply.opened(handle, FopenFlags::empty()),
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn read(
            &self,
            _request: &Request,
            inode: INodeNo,
            handle: FileHandle,
            offset: u64,
            size: u32,
            _flags: OpenFlags,
            _lock_owner: Option<LockOwner>,
            reply: ReplyData,
        ) {
            let result = self
                .open_path(handle, inode)
                .and_then(|path| Ok(self.client.read_range(&path, offset, size)?));
            match result {
                Ok(data) => reply.data(&data),
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn write(
            &self,
            _request: &Request,
            inode: INodeNo,
            _handle: FileHandle,
            offset: u64,
            input: &[u8],
            _write_flags: WriteFlags,
            _flags: OpenFlags,
            _lock_owner: Option<LockOwner>,
            reply: ReplyWrite,
        ) {
            // The initial adapter persists a complete new file version for an
            // offset write. Chunk storage is a later optimization.
            let result = self.entry(inode).and_then(|entry| {
                let mut data = self.client.read(&entry.path)?;
                let start = usize::try_from(offset).context("write offset is too large")?;
                let end = start
                    .checked_add(input.len())
                    .context("write is too large")?;
                if data.len() < end {
                    data.resize(end, 0);
                }
                data[start..end].copy_from_slice(input);
                self.client.write(&entry.path, &data)?;
                Ok(u32::try_from(input.len())?)
            });
            match result {
                Ok(count) => reply.written(count),
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn create(
            &self,
            _request: &Request,
            parent: INodeNo,
            name: &OsStr,
            _mode: u32,
            _umask: u32,
            _flags: i32,
            reply: ReplyCreate,
        ) {
            let result = self
                .child_path(parent, name)
                .and_then(|path| self.client.write_entry(&path, &[]).map_err(Into::into));
            match result {
                Ok(entry) => {
                    self.remember(&entry);
                    match self.allocate_handle(entry.path.clone()) {
                        Ok(handle) => reply.created(
                            &TTL,
                            &Self::attr(&entry),
                            Self::generation(&entry),
                            handle,
                            FopenFlags::empty(),
                        ),
                        Err(_) => reply.error(Errno::EIO),
                    }
                }
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn mkdir(
            &self,
            _request: &Request,
            parent: INodeNo,
            name: &OsStr,
            _mode: u32,
            _umask: u32,
            reply: ReplyEntry,
        ) {
            let result = self
                .child_path(parent, name)
                .and_then(|path| self.client.mkdir_entry(&path, false).map_err(Into::into));
            match result {
                Ok(entry) => {
                    self.remember(&entry);
                    reply.entry(&TTL, &Self::attr(&entry), Self::generation(&entry));
                }
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn unlink(&self, _request: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
            self.remove_child(parent, name, reply);
        }

        fn rmdir(&self, _request: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
            self.remove_child(parent, name, reply);
        }

        fn rename(
            &self,
            _request: &Request,
            parent: INodeNo,
            name: &OsStr,
            new_parent: INodeNo,
            new_name: &OsStr,
            flags: RenameFlags,
            reply: ReplyEmpty,
        ) {
            if !flags.is_empty() {
                reply.error(Errno::EINVAL);
                return;
            }
            let result = self.child_path(parent, name).and_then(|source| {
                let destination = self.child_path(new_parent, new_name)?;
                self.client.move_path(&source, &destination)?;
                Ok(())
            });
            match result {
                Ok(()) => reply.ok(),
                Err(_) => reply.error(Errno::EIO),
            }
        }

        fn readdir(
            &self,
            _request: &Request,
            inode: INodeNo,
            _handle: FileHandle,
            offset: u64,
            mut reply: ReplyDirectory,
        ) {
            let result = self.entry(inode).and_then(|directory| {
                let mut entries = vec![
                    (inode, FileType::Directory, ".".to_owned()),
                    (
                        self.parent_inode(&directory),
                        FileType::Directory,
                        "..".to_owned(),
                    ),
                ];
                entries.extend(
                    self.client
                        .list(&directory.path)?
                        .into_iter()
                        .map(|entry| (Self::inode(&entry), Self::kind(&entry), entry.name)),
                );
                Ok(entries)
            });
            let Ok(entries) = result else {
                reply.error(Errno::EIO);
                return;
            };
            let start = usize::try_from(offset).unwrap_or(usize::MAX);
            for (index, (inode, kind, name)) in entries.into_iter().enumerate().skip(start) {
                if reply.add(inode, (index + 1) as u64, kind, name) {
                    break;
                }
            }
            reply.ok();
        }

        fn flush(
            &self,
            _request: &Request,
            _inode: INodeNo,
            _handle: FileHandle,
            _lock_owner: LockOwner,
            reply: ReplyEmpty,
        ) {
            reply.ok();
        }

        fn release(
            &self,
            _request: &Request,
            _inode: INodeNo,
            handle: FileHandle,
            _flags: OpenFlags,
            _lock_owner: Option<LockOwner>,
            _flush: bool,
            reply: ReplyEmpty,
        ) {
            if let Ok(mut files) = self.open_files.lock() {
                files.remove(&handle);
            }
            reply.ok();
        }

        fn fsync(
            &self,
            _request: &Request,
            _inode: INodeNo,
            _handle: FileHandle,
            _datasync: bool,
            reply: ReplyEmpty,
        ) {
            reply.ok();
        }
    }

    impl PostgreOsFilesystem {
        fn remove_child(&self, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
            let result = self.child_path(parent, name).and_then(|path| {
                self.client.remove(&path, false)?;
                Ok(())
            });
            match result {
                Ok(()) => reply.ok(),
                Err(_) => reply.error(Errno::EIO),
            }
        }
    }

    #[allow(dead_code)]
    fn _mountpoint_is_directory(path: &Path) -> Result<()> {
        if !path.is_dir() {
            bail!("mount point is not a directory: {}", path.display());
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn main() -> ExitCode {
    match linux::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pgos-mount: {error:#}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> ExitCode {
    eprintln!("pgos-mount: the first filesystem adapter supports Linux only");
    ExitCode::FAILURE
}
