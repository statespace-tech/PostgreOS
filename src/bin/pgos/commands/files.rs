//! File operation commands backed by the public SQL API.

use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use postgreos::postgres::{Database, ImportEntry};
use uuid::Uuid;
use walkdir::{DirEntry, IntoIter, WalkDir};

use crate::args::{CpArgs, RmArgs};
use crate::client::FileClient;
use crate::multicall::map_path;

pub(super) fn write(
    database: &Database,
    volume: Uuid,
    path: &str,
    data: Option<String>,
    multicall: bool,
) -> Result<()> {
    let bytes = if let Some(data) = data {
        data.into_bytes()
    } else {
        let mut data = Vec::new();
        io::stdin().read_to_end(&mut data)?;
        data
    };
    database.write(volume, &map_path(path, multicall)?, &bytes)?;
    Ok(())
}

pub(super) fn import(
    database: &Database,
    volume: Uuid,
    source: &Path,
    destination: &str,
) -> Result<()> {
    let metadata = fs::symlink_metadata(source)?;
    if metadata.is_file() && metadata.len() >= 1024 * 1024 * 1024 {
        let reader = io::BufReader::new(fs::File::open(source)?);
        database.import_text(volume, destination, reader)?;
        return Ok(());
    }
    let entries = LocalTree::new(source)?;
    database.import(volume, destination, entries)?;
    Ok(())
}

struct LocalTree {
    root: PathBuf,
    entries: IntoIter,
}

impl LocalTree {
    fn new(root: &Path) -> Result<Self> {
        // Fail before opening the transaction for the common missing-source
        // case. Later read errors still roll back the complete COPY operation.
        fs::symlink_metadata(root)
            .with_context(|| format!("cannot access import source {}", root.display()))?;
        Ok(Self {
            root: root.to_path_buf(),
            entries: WalkDir::new(root).follow_links(false).into_iter(),
        })
    }

    fn convert(&self, entry: &DirEntry) -> Result<ImportEntry> {
        let relative = entry
            .path()
            .strip_prefix(&self.root)
            .context("walked path is outside the import source")?;
        let relative_path = relative
            .to_str()
            .with_context(|| format!("path is not valid UTF-8: {}", entry.path().display()))?
            .replace(std::path::MAIN_SEPARATOR, "/");
        let metadata = fs::symlink_metadata(entry.path())
            .with_context(|| format!("cannot read metadata for {}", entry.path().display()))?;
        let file_type = metadata.file_type();

        let (kind, content, link_target) = if file_type.is_file() {
            anyhow::ensure!(
                metadata.len() < 1024 * 1024 * 1024,
                "tree import contains a file above the PostgreSQL value limit; import that file separately: {}",
                entry.path().display()
            );
            (
                1,
                fs::read(entry.path())
                    .with_context(|| format!("cannot read {}", entry.path().display()))?,
                String::new(),
            )
        } else if file_type.is_dir() {
            (2, Vec::new(), String::new())
        } else if file_type.is_symlink() {
            let target = fs::read_link(entry.path())
                .with_context(|| format!("cannot read link {}", entry.path().display()))?;
            let target = target.to_str().with_context(|| {
                format!(
                    "symbolic-link target is not valid UTF-8: {}",
                    entry.path().display()
                )
            })?;
            (3, Vec::new(), target.to_owned())
        } else {
            bail!("unsupported file type: {}", entry.path().display());
        };

        Ok(ImportEntry {
            relative_path,
            kind,
            content,
            mode: i32::try_from(metadata.mode() & 0o7777).context("mode does not fit in i32")?,
            uid: i32::try_from(metadata.uid()).context("UID does not fit in i32")?,
            gid: i32::try_from(metadata.gid()).context("GID does not fit in i32")?,
            mtime_seconds: metadata.mtime(),
            mtime_nanoseconds: i32::try_from(metadata.mtime_nsec())
                .context("mtime nanoseconds do not fit in i32")?,
            link_target,
        })
    }
}

impl Iterator for LocalTree {
    type Item = Result<ImportEntry>;

    fn next(&mut self) -> Option<Self::Item> {
        let entry = match self.entries.next()? {
            Ok(entry) => entry,
            Err(error) => return Some(Err(error.into())),
        };
        Some(self.convert(&entry))
    }
}

pub(super) fn copy(client: &FileClient, options: &CpArgs, multicall: bool) -> Result<()> {
    client.copy(
        &map_path(&options.source, multicall)?,
        &map_path(&options.destination, multicall)?,
        options.recursive,
    )?;
    Ok(())
}

pub(super) fn remove(client: &FileClient, options: &RmArgs, multicall: bool) -> Result<()> {
    let paths = options
        .paths
        .iter()
        .map(|path| map_path(path, multicall))
        .collect::<Result<Vec<_>>>()?;
    client.remove_many(&paths, options.recursive, options.force)?;
    Ok(())
}
