//! `PostgreSQL` client for the public `pgos` SQL API.

use std::cell::RefCell;

pub use crate::core::Entry;
use crate::core::path;
use anyhow::{Context, Result, bail};
use diesel::Connection as _;
use diesel::connection::SimpleConnection;
use diesel::pg::{CopyFormat, PgConnection};
use diesel::prelude::*;
use diesel::r2d2::{ConnectionManager, Pool, PooledConnection};
use diesel::sql_types::{
    Array, BigInt, Binary, Integer, Nullable, SmallInt, Text, Uuid as SqlUuid,
};
use uuid::Uuid;

mod blocks;

diesel::table! {
    pg_temp.pgos_import_staging (batch_id, ordinal) {
        batch_id -> Uuid,
        ordinal -> BigInt,
        relative_path -> Text,
        kind -> SmallInt,
        content -> Binary,
        mode -> Integer,
        uid -> Integer,
        gid -> Integer,
        mtime_seconds -> BigInt,
        mtime_nanoseconds -> Integer,
        link_target -> Text,
    }
}

// Embed one canonical schema so every component uses the same database contract.
const INITIAL_SCHEMA: &str = include_str!("sql/001_initial.sql");
type Connection = PooledConnection<ConnectionManager<PgConnection>>;

/// One local entry for a transaction-scoped batch import.
#[derive(Debug)]
pub struct ImportEntry {
    pub relative_path: String,
    pub kind: i16,
    pub content: Vec<u8>,
    pub mode: i32,
    pub uid: i32,
    pub gid: i32,
    pub mtime_seconds: i64,
    pub mtime_nanoseconds: i32,
    pub link_target: String,
}

#[derive(QueryableByName)]
struct EntryRow {
    #[diesel(sql_type = BigInt)]
    pub id: i64,
    #[diesel(sql_type = Text)]
    pub path: String,
    #[diesel(sql_type = Text)]
    pub name: String,
    #[diesel(sql_type = SmallInt)]
    pub kind: i16,
    #[diesel(sql_type = Integer)]
    pub mode: i32,
    #[diesel(sql_type = Integer)]
    pub uid: i32,
    #[diesel(sql_type = Integer)]
    pub gid: i32,
    #[diesel(sql_type = BigInt)]
    pub size: i64,
    #[diesel(sql_type = BigInt)]
    pub generation: i64,
    #[diesel(sql_type = BigInt)]
    pub atime_seconds: i64,
    #[diesel(sql_type = Integer)]
    pub atime_nanoseconds: i32,
    #[diesel(sql_type = BigInt)]
    pub mtime_seconds: i64,
    #[diesel(sql_type = Integer)]
    pub mtime_nanoseconds: i32,
    #[diesel(sql_type = BigInt)]
    pub ctime_seconds: i64,
    #[diesel(sql_type = Integer)]
    pub ctime_nanoseconds: i32,
}

impl From<EntryRow> for Entry {
    fn from(row: EntryRow) -> Self {
        Self {
            id: row.id,
            path: row.path,
            name: row.name,
            kind: row.kind,
            mode: row.mode,
            uid: row.uid,
            gid: row.gid,
            size: row.size,
            generation: row.generation,
            atime_seconds: row.atime_seconds,
            atime_nanoseconds: u32::try_from(row.atime_nanoseconds).unwrap_or(0),
            mtime_seconds: row.mtime_seconds,
            mtime_nanoseconds: u32::try_from(row.mtime_nanoseconds).unwrap_or(0),
            ctime_seconds: row.ctime_seconds,
            ctime_nanoseconds: u32::try_from(row.ctime_nanoseconds).unwrap_or(0),
        }
    }
}

#[derive(QueryableByName)]
struct VolumeRow {
    #[diesel(sql_type = SqlUuid)]
    id: Uuid,
    #[diesel(sql_type = Text)]
    name: String,
}

#[derive(QueryableByName)]
struct IdRow {
    #[diesel(sql_type = SqlUuid)]
    id: Uuid,
}

#[derive(QueryableByName)]
struct CountRow {
    #[diesel(sql_type = BigInt)]
    value: i64,
}

#[derive(QueryableByName)]
struct DataRow {
    #[diesel(sql_type = Binary)]
    data: Vec<u8>,
}

#[derive(QueryableByName)]
struct PathRow {
    #[diesel(sql_type = Text)]
    path: String,
}

#[derive(QueryableByName)]
struct NameRow {
    #[diesel(sql_type = Text)]
    name: String,
}

#[derive(QueryableByName)]
struct ReadRow {
    #[diesel(sql_type = Text)]
    path: String,
    #[diesel(sql_type = Nullable<Binary>)]
    data: Option<Vec<u8>>,
}

#[derive(Debug, Clone)]
pub struct TextFile {
    pub path: String,
    pub text: String,
}

#[derive(QueryableByName)]
struct TextFileRow {
    #[diesel(sql_type = Text)]
    path: String,
    #[diesel(sql_type = Text)]
    text_content: String,
}

#[derive(Clone)]
pub struct Database {
    pool: Pool<ConnectionManager<PgConnection>>,
}

impl Database {
    pub fn connect(url: &str) -> Result<Self> {
        Self::connect_with_pool(url, 1, None)
    }

    /// Connect a long-lived service with capacity for concurrent operations.
    pub fn connect_pooled(url: &str) -> Result<Self> {
        Self::connect_with_pool(url, 16, Some(1))
    }

    fn connect_with_pool(url: &str, max_size: u32, min_idle: Option<u32>) -> Result<Self> {
        let manager = ConnectionManager::<PgConnection>::new(url);
        let pool = Pool::builder()
            .max_size(max_size)
            .min_idle(min_idle)
            .build(manager)
            .with_context(|| format!("could not connect to PostgreSQL at {url:?}"))?;
        Ok(Self { pool })
    }

    fn connection(&self) -> Result<Connection> {
        self.pool
            .get()
            .context("could not acquire a PostgreSQL connection")
    }

    pub fn migrate(&self) -> Result<()> {
        let mut connection = self.connection()?;
        connection
            .transaction::<(), anyhow::Error, _>(|connection| {
                // Concurrent `pgos init` calls must not update the catalogs at
                // the same time. The lock lasts only for this transaction.
                diesel::sql_query("SELECT pg_advisory_xact_lock(70155083)").execute(connection)?;
                connection.batch_execute(
                    "CREATE SCHEMA IF NOT EXISTS pgos_private;
                     CREATE TABLE IF NOT EXISTS pgos_private.schema_version (
                         singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
                         version integer NOT NULL
                     );",
                )?;
                let installed = diesel::sql_query(
                    "INSERT INTO pgos_private.schema_version(singleton, version) VALUES (true, 1)
                     ON CONFLICT DO NOTHING",
                )
                .execute(connection)?;
                if installed == 1 {
                    connection.batch_execute(INITIAL_SCHEMA)?;
                }
                let version: CountRow = diesel::sql_query(
                    "SELECT version::bigint AS value
                     FROM pgos_private.schema_version WHERE singleton",
                )
                .get_result(connection)?;
                if version.value != 1 {
                    bail!(
                        "database uses unsupported PostgreOS schema version {}",
                        version.value
                    );
                }
                Ok(())
            })
            .context("could not install the PostgreOS schema")
    }

    pub fn create_volume(&self, name: &str) -> Result<Uuid> {
        let mut connection = self.connection()?;
        let id = Uuid::new_v4();
        let row: IdRow = diesel::sql_query("SELECT pgos.create_volume($1, $2) AS id")
            .bind::<SqlUuid, _>(id)
            .bind::<Text, _>(name)
            .get_result(&mut connection)
            .with_context(|| format!("could not create volume {name:?}"))?;
        Ok(row.id)
    }

    pub fn volumes(&self) -> Result<Vec<(Uuid, String)>> {
        let mut connection = self.connection()?;
        let rows: Vec<VolumeRow> =
            diesel::sql_query("SELECT id, name FROM pgos.volumes()").load(&mut connection)?;
        Ok(rows.into_iter().map(|row| (row.id, row.name)).collect())
    }

    pub fn remove_volume(&self, volume: Uuid) -> Result<()> {
        let mut connection = self.connection()?;
        diesel::sql_query("SELECT pgos.remove_volume($1)")
            .bind::<SqlUuid, _>(volume)
            .execute(&mut connection)?;
        Ok(())
    }

    pub fn resolve_volume(&self, value: &str) -> Result<Uuid> {
        if let Ok(id) = Uuid::parse_str(value) {
            return Ok(id);
        }
        let mut connection = self.connection()?;
        let row: VolumeRow =
            diesel::sql_query("SELECT id, name FROM pgos.volumes() WHERE name = $1")
                .bind::<Text, _>(value)
                .get_result(&mut connection)
                .with_context(|| format!("volume {value:?} does not exist"))?;
        Ok(row.id)
    }

    pub fn list(&self, volume: Uuid, target: &str) -> Result<Vec<Entry>> {
        self.entries("pgos.list", volume, target)
    }

    pub fn list_names(&self, volume: Uuid, target: &str) -> Result<Vec<String>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let rows: Vec<NameRow> = diesel::sql_query("SELECT name FROM pgos.list_names($1, $2)")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .load(&mut connection)?;
        Ok(rows.into_iter().map(|row| row.name).collect())
    }

    pub fn list_output(&self, volume: Uuid, target: &str, all: bool) -> Result<Vec<u8>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: DataRow = diesel::sql_query("SELECT pgos.list_output($1, $2, $3) AS data")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .bind::<diesel::sql_types::Bool, _>(all)
            .get_result(&mut connection)?;
        Ok(row.data)
    }

    pub fn walk(&self, volume: Uuid, target: &str) -> Result<Vec<Entry>> {
        self.entries("pgos.walk", volume, target)
    }

    pub fn find(
        &self,
        volume: Uuid,
        target: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
    ) -> Result<Vec<Entry>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let rows: Vec<EntryRow> = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM mtime))::bigint AS atime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.find_entries($1, $2, $3, $4)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(target)
        .bind::<Nullable<Text>, _>(name_pattern.map(str::to_owned))
        .bind::<Nullable<SmallInt>, _>(kind)
        .load(&mut connection)?;
        Ok(rows.into_iter().map(Entry::from).collect())
    }

    fn entries(&self, function: &str, volume: Uuid, target: &str) -> Result<Vec<Entry>> {
        let target = path::normalize(target)?;
        // Callers pass one of the fixed public functions above. User input is
        // bound separately and never becomes part of this SQL identifier.
        // Enumeration functions return one timestamp to keep their rows small.
        // FUSE resolves exact attributes through `stat` or `inode` after lookup.
        let query = format!(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM mtime))::bigint AS atime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM {function}($1, $2)"
        );
        let mut connection = self.connection()?;
        let rows: Vec<EntryRow> = diesel::sql_query(query)
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .load(&mut connection)?;
        Ok(rows.into_iter().map(Entry::from).collect())
    }

    pub fn stat(&self, volume: Uuid, target: &str) -> Result<Entry> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: EntryRow = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM atime))::bigint AS atime_seconds,
                    (extract(microseconds FROM atime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM ctime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM ctime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.stat($1, $2)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(&target)
        .get_result(&mut connection)
        .with_context(|| format!("path {target:?} does not exist"))?;
        Ok(row.into())
    }

    pub fn inode(&self, volume: Uuid, id: i64) -> Result<Entry> {
        let mut connection = self.connection()?;
        let row: EntryRow = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM atime))::bigint AS atime_seconds,
                    (extract(microseconds FROM atime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM ctime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM ctime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.inode($1, $2)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<BigInt, _>(id)
        .get_result(&mut connection)
        .with_context(|| format!("inode {id} does not exist"))?;
        Ok(row.into())
    }

    pub fn read(&self, volume: Uuid, target: &str) -> Result<Vec<u8>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: DataRow = diesel::sql_query("SELECT pgos.read_file($1, $2) AS data")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .get_result(&mut connection)?;
        Ok(row.data)
    }

    pub fn read_many(&self, volume: Uuid, targets: &[String]) -> Result<Vec<Vec<u8>>> {
        let targets = targets
            .iter()
            .map(|target| path::normalize(target).map_err(anyhow::Error::from))
            .collect::<Result<Vec<_>>>()?;
        let mut connection = self.connection()?;
        let rows: Vec<ReadRow> =
            diesel::sql_query("SELECT path, data FROM pgos.read_files($1, $2)")
                .bind::<SqlUuid, _>(volume)
                .bind::<Array<Text>, _>(&targets)
                .load(&mut connection)?;
        rows.into_iter()
            .map(|row| {
                row.data
                    .with_context(|| format!("path {:?} is not a regular file", row.path))
            })
            .collect()
    }

    pub fn cat(&self, volume: Uuid, targets: &[String]) -> Result<Vec<u8>> {
        let targets = targets
            .iter()
            .map(|target| path::normalize(target).map_err(anyhow::Error::from))
            .collect::<Result<Vec<_>>>()?;
        let mut connection = self.connection()?;
        let row: DataRow = diesel::sql_query("SELECT pgos.cat_command_files($1, $2) AS data")
            .bind::<SqlUuid, _>(volume)
            .bind::<Array<Text>, _>(&targets)
            .get_result(&mut connection)?;
        Ok(row.data)
    }

    pub fn find_paths(
        &self,
        volume: Uuid,
        target: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
    ) -> Result<Vec<String>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let rows: Vec<PathRow> =
            diesel::sql_query("SELECT path FROM pgos.find_paths($1, $2, $3, $4)")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(target)
                .bind::<Nullable<Text>, _>(name_pattern.map(str::to_owned))
                .bind::<Nullable<SmallInt>, _>(kind)
                .load(&mut connection)?;
        Ok(rows.into_iter().map(|row| row.path).collect())
    }

    pub fn find_output(
        &self,
        volume: Uuid,
        target: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
        path_prefix: &str,
    ) -> Result<Vec<u8>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: DataRow =
            diesel::sql_query("SELECT pgos.find_command_output($1, $2, $3, $4, $5) AS data")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(target)
                .bind::<Nullable<Text>, _>(name_pattern.map(str::to_owned))
                .bind::<Nullable<SmallInt>, _>(kind)
                .bind::<Text, _>(path_prefix)
                .get_result(&mut connection)?;
        Ok(row.data)
    }

    pub fn disk_usage(&self, volume: Uuid, target: &str) -> Result<i64> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: CountRow = diesel::sql_query("SELECT pgos.disk_usage_fast($1, $2) AS value")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .get_result(&mut connection)?;
        Ok(row.value)
    }

    pub fn write(&self, volume: Uuid, target: &str, data: &[u8]) -> Result<i64> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: CountRow = diesel::sql_query("SELECT pgos.write_file($1, $2, $3) AS value")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .bind::<Binary, _>(data)
            .get_result(&mut connection)?;
        Ok(row.value)
    }

    /// Import a streamed tree with one connection, one transaction, and two
    /// `PostgreSQL` COPY operations. Only the current file is held in memory.
    pub fn import<I>(&self, volume: Uuid, destination: &str, entries: I) -> Result<i64>
    where
        I: IntoIterator<Item = Result<ImportEntry>>,
    {
        use self::pgos_import_staging::dsl;

        let destination = path::normalize(destination)?;
        let batch = Uuid::new_v4();
        let entries = RefCell::new(entries.into_iter());
        let mut connection = self.connection()?;

        connection.transaction::<i64, anyhow::Error, _>(|connection| {
            diesel::sql_query("SELECT pgos.prepare_import($1, $2, $3)")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(&destination)
                .bind::<SqlUuid, _>(batch)
                .execute(connection)?;

            let copy = diesel::copy_from(pgos_import_staging::table)
                .from_raw_data(
                    (
                        dsl::batch_id,
                        dsl::ordinal,
                        dsl::relative_path,
                        dsl::kind,
                        dsl::content,
                        dsl::mode,
                        dsl::uid,
                        dsl::gid,
                        dsl::mtime_seconds,
                        dsl::mtime_nanoseconds,
                        dsl::link_target,
                    ),
                    |sink| -> diesel::result::QueryResult<()> {
                        let mut writer = csv::WriterBuilder::new()
                            .has_headers(false)
                            .quote_style(csv::QuoteStyle::Always)
                            .from_writer(sink);
                        for (ordinal, entry) in entries.borrow_mut().by_ref().enumerate() {
                            let entry = entry.map_err(|error| {
                                diesel::result::Error::SerializationError(
                                    error.into_boxed_dyn_error(),
                                )
                            })?;
                            let ordinal = i64::try_from(ordinal).map_err(|error| {
                                diesel::result::Error::SerializationError(Box::new(error))
                            })?;
                            writer
                                .write_record(&[
                                    batch.to_string(),
                                    ordinal.to_string(),
                                    entry.relative_path,
                                    entry.kind.to_string(),
                                    format!("\\x{}", hex::encode(entry.content)),
                                    entry.mode.to_string(),
                                    entry.uid.to_string(),
                                    entry.gid.to_string(),
                                    entry.mtime_seconds.to_string(),
                                    entry.mtime_nanoseconds.to_string(),
                                    entry.link_target,
                                ])
                                .map_err(|error| {
                                    diesel::result::Error::SerializationError(Box::new(error))
                                })?;
                        }
                        writer.flush().map_err(|error| {
                            diesel::result::Error::SerializationError(Box::new(error))
                        })?;
                        Ok(())
                    },
                )
                .with_format(CopyFormat::Csv);
            diesel::prelude::ExecuteCopyFromDsl::execute(copy, connection)?;

            let row: CountRow = diesel::sql_query("SELECT pgos.apply_import($1, $2, $3) AS value")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(&destination)
                .bind::<SqlUuid, _>(batch)
                .get_result(connection)?;
            Ok(row.value)
        })
    }

    pub fn mkdir(&self, volume: Uuid, target: &str, parents: bool) -> Result<()> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        diesel::sql_query("SELECT pgos.mkdir($1, $2, $3)")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .bind::<diesel::sql_types::Bool, _>(parents)
            .execute(&mut connection)?;
        Ok(())
    }

    pub fn write_entry(&self, volume: Uuid, target: &str, data: &[u8]) -> Result<Entry> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: EntryRow = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM atime))::bigint AS atime_seconds,
                    (extract(microseconds FROM atime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM ctime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM ctime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.write_file_entry($1, $2, $3)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(&target)
        .bind::<Binary, _>(data)
        .get_result(&mut connection)?;
        Ok(row.into())
    }

    pub fn mkdir_entry(&self, volume: Uuid, target: &str, parents: bool) -> Result<Entry> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: EntryRow = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM atime))::bigint AS atime_seconds,
                    (extract(microseconds FROM atime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM ctime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM ctime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.mkdir_entry($1, $2, $3)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(&target)
        .bind::<diesel::sql_types::Bool, _>(parents)
        .get_result(&mut connection)?;
        Ok(row.into())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn set_times(
        &self,
        volume: Uuid,
        target: &str,
        atime_seconds: i64,
        atime_nanoseconds: u32,
        mtime_seconds: i64,
        mtime_nanoseconds: u32,
    ) -> Result<Entry> {
        let target = path::normalize(target)?;
        let atime_nanoseconds = i32::try_from(atime_nanoseconds)?;
        let mtime_nanoseconds = i32::try_from(mtime_nanoseconds)?;
        let mut connection = self.connection()?;
        let row: EntryRow = diesel::sql_query(
            "SELECT id, path, name, kind, mode, uid, gid, size, generation,
                    floor(extract(epoch FROM atime))::bigint AS atime_seconds,
                    (extract(microseconds FROM atime)::bigint % 1000000)::integer AS atime_nanoseconds,
                    floor(extract(epoch FROM mtime))::bigint AS mtime_seconds,
                    (extract(microseconds FROM mtime)::bigint % 1000000)::integer AS mtime_nanoseconds,
                    floor(extract(epoch FROM ctime))::bigint AS ctime_seconds,
                    (extract(microseconds FROM ctime)::bigint % 1000000)::integer AS ctime_nanoseconds
             FROM pgos.set_times($1, $2, $3, $4, $5, $6)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(&target)
        .bind::<BigInt, _>(atime_seconds)
        .bind::<Integer, _>(atime_nanoseconds)
        .bind::<BigInt, _>(mtime_seconds)
        .bind::<Integer, _>(mtime_nanoseconds)
        .get_result(&mut connection)?;
        Ok(row.into())
    }

    pub fn mkdir_many(&self, volume: Uuid, targets: &[String], parents: bool) -> Result<()> {
        if targets.is_empty() {
            bail!("at least one path is required");
        }
        let targets = targets
            .iter()
            .map(|target| path::normalize(target).map_err(anyhow::Error::from))
            .collect::<Result<Vec<_>>>()?;
        let mut connection = self.connection()?;
        diesel::sql_query("SELECT pgos.mkdir_many($1, $2, $3)")
            .bind::<SqlUuid, _>(volume)
            .bind::<Array<Text>, _>(&targets)
            .bind::<diesel::sql_types::Bool, _>(parents)
            .execute(&mut connection)?;
        Ok(())
    }

    pub fn copy(
        &self,
        volume: Uuid,
        source: &str,
        destination: &str,
        recursive: bool,
    ) -> Result<i64> {
        self.path_count("pgos.copy", volume, source, destination, Some(recursive))
    }

    pub fn move_path(&self, volume: Uuid, source: &str, destination: &str) -> Result<i64> {
        self.path_count("pgos.move_command", volume, source, destination, None)
    }

    fn path_count(
        &self,
        function: &str,
        volume: Uuid,
        source: &str,
        destination: &str,
        recursive: Option<bool>,
    ) -> Result<i64> {
        let source = path::normalize(source)?;
        let destination = path::normalize(destination)?;
        let mut connection = self.connection()?;
        let row: CountRow = if let Some(recursive) = recursive {
            diesel::sql_query(format!("SELECT {function}($1, $2, $3, $4) AS value"))
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(source)
                .bind::<Text, _>(destination)
                .bind::<diesel::sql_types::Bool, _>(recursive)
                .get_result(&mut connection)?
        } else {
            diesel::sql_query(format!("SELECT {function}($1, $2, $3) AS value"))
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(source)
                .bind::<Text, _>(destination)
                .get_result(&mut connection)?
        };
        Ok(row.value)
    }

    pub fn remove(&self, volume: Uuid, target: &str, recursive: bool) -> Result<i64> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: CountRow = diesel::sql_query("SELECT pgos.remove($1, $2, $3) AS value")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .bind::<diesel::sql_types::Bool, _>(recursive)
            .get_result(&mut connection)?;
        Ok(row.value)
    }

    pub fn remove_many(
        &self,
        volume: Uuid,
        targets: &[String],
        recursive: bool,
        force: bool,
    ) -> Result<i64> {
        if targets.is_empty() {
            bail!("at least one path is required");
        }
        let targets = targets
            .iter()
            .map(|target| path::normalize(target).map_err(anyhow::Error::from))
            .collect::<Result<Vec<_>>>()?;
        let mut connection = self.connection()?;
        let row: CountRow = diesel::sql_query("SELECT pgos.remove_many($1, $2, $3, $4) AS value")
            .bind::<SqlUuid, _>(volume)
            .bind::<Array<Text>, _>(&targets)
            .bind::<diesel::sql_types::Bool, _>(recursive)
            .bind::<diesel::sql_types::Bool, _>(force)
            .get_result(&mut connection)?;
        Ok(row.value)
    }

    pub fn search_literal(&self, volume: Uuid, root: &str, needle: &str) -> Result<Vec<String>> {
        let root = path::normalize(root)?;
        let mut connection = self.connection()?;
        let rows: Vec<PathRow> =
            diesel::sql_query("SELECT path FROM pgos.search_literal($1, $2, $3)")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(root)
                .bind::<Text, _>(needle)
                .load(&mut connection)?;
        Ok(rows.into_iter().map(|row| row.path).collect())
    }

    pub fn search_literal_files(
        &self,
        volume: Uuid,
        root: &str,
        needle: &str,
    ) -> Result<Vec<TextFile>> {
        let root = path::normalize(root)?;
        let mut connection = self.connection()?;
        let rows: Vec<TextFileRow> = diesel::sql_query(
            "SELECT path, text_content FROM pgos.search_literal_files($1, $2, $3)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(root)
        .bind::<Text, _>(needle)
        .load(&mut connection)?;
        Ok(rows
            .into_iter()
            .map(|row| TextFile {
                path: row.path,
                text: row.text_content,
            })
            .collect())
    }

    pub fn search_literal_files_any(
        &self,
        volume: Uuid,
        root: &str,
        needles: &[String],
    ) -> Result<Vec<TextFile>> {
        self.search_literal_files_filtered(volume, root, needles, &[])
    }

    pub fn search_literal_files_filtered(
        &self,
        volume: Uuid,
        root: &str,
        needles: &[String],
        file_suffixes: &[String],
    ) -> Result<Vec<TextFile>> {
        self.search_candidate_files(volume, root, needles, file_suffixes, None)
    }

    pub fn search_candidate_files(
        &self,
        volume: Uuid,
        root: &str,
        needles: &[String],
        file_suffixes: &[String],
        identifier_regex: Option<&str>,
    ) -> Result<Vec<TextFile>> {
        if let [needle] = needles
            && file_suffixes.is_empty()
            && identifier_regex.is_none()
        {
            return self.search_literal_files(volume, root, needle);
        }
        let root = path::normalize(root)?;
        let mut connection = self.connection()?;
        let rows: Vec<TextFileRow> = diesel::sql_query(
            "SELECT DISTINCT ON (result.path COLLATE \"C\") result.path, result.text_content \
             FROM unnest($3::text[]) AS input(needle) \
             CROSS JOIN LATERAL pgos.search_candidate_files($1, $2, input.needle, $5) AS result \
             WHERE cardinality($4::text[]) = 0 OR EXISTS (\
                 SELECT 1 FROM unnest($4::text[]) suffix WHERE right(result.path, length(suffix)) = suffix\
             ) \
             ORDER BY result.path COLLATE \"C\"",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(root)
        .bind::<Array<Text>, _>(needles)
        .bind::<Array<Text>, _>(file_suffixes)
        .bind::<diesel::sql_types::Nullable<Text>, _>(identifier_regex)
        .load(&mut connection)?;
        Ok(rows
            .into_iter()
            .map(|row| TextFile {
                path: row.path,
                text: row.text_content,
            })
            .collect())
    }
}
