//! Bounded large-text storage. COPY and single-row loading use libpq through
//! Diesel; neither imports nor reads buffer the complete file.

use std::io::{BufRead, Write};

use diesel::pg::PgRowByRowLoadingMode;

use super::*;

const BLOCK_BYTES: usize = 8 * 1024;
const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

diesel::table! {
    content_segment (segment_id, object_id, ordinal) {
        segment_id -> Uuid,
        object_id -> Uuid,
        volume_id -> Uuid,
        ordinal -> BigInt,
        byte_offset -> BigInt,
        first_line -> BigInt,
        body -> Text,
    }
}

#[derive(QueryableByName)]
struct BlockRow {
    #[diesel(sql_type = BigInt)]
    first_line: i64,
    #[diesel(sql_type = Text)]
    body: String,
}

#[derive(QueryableByName)]
struct PathBlockRow {
    #[diesel(sql_type = Text)]
    path: String,
    #[diesel(sql_type = BigInt)]
    first_line: i64,
    #[diesel(sql_type = Text)]
    body: String,
}

#[derive(QueryableByName)]
struct SearchScopeRow {
    #[diesel(sql_type = BigInt)]
    zone_id: i64,
    #[diesel(sql_type = Text)]
    zone_path: String,
    #[diesel(sql_type = Text)]
    relative_path: String,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    has_descendants: bool,
    #[diesel(sql_type = Array<SqlUuid>)]
    segment_ids: Vec<Uuid>,
}

impl Database {
    /// Stream candidate blocks from one indexed SQL query in path order.
    pub fn candidate_blocks(
        &self,
        volume: Uuid,
        target: &str,
        literals: Option<&[String]>,
        file_suffixes: &[String],
        output: impl FnMut(&str, i64, &str) -> Result<()>,
    ) -> Result<()> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        if let Some([literal]) = literals {
            let scope: SearchScopeRow = diesel::sql_query(
                "SELECT location.zone_id, location.zone_path,
                        location.relative_path,
                        EXISTS (
                            SELECT 1 FROM pgos_private.zones zone
                            WHERE zone.volume_id = $1
                              AND zone.id <> location.zone_id
                              AND ($2 = '/' OR zone.path = $2
                                   OR starts_with(zone.path, $2 || '/'))
                        ) AS has_descendants,
                        COALESCE((
                            SELECT array_agg(DISTINCT object.segment_id)
                            FROM pgos_private.zone_entries entry
                            JOIN pgos_private.content_objects object
                              ON object.id = entry.content_object
                             AND object.volume_id = entry.volume_id
                            WHERE entry.volume_id = $1
                              AND entry.zone_id = location.zone_id
                              AND object.segment_id IS NOT NULL
                              AND (location.relative_path = ''
                                   OR entry.relative_path = location.relative_path
                                   OR starts_with(entry.relative_path,
                                                  location.relative_path || '/'))
                        ), ARRAY[]::uuid[]) AS segment_ids
                 FROM pgos_private.locate_zone($1, $2) location",
            )
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(&target)
            .get_result(&mut connection)?;
            if !scope.has_descendants {
                let rows = diesel::sql_query(
                    "SELECT CASE WHEN $3 = '/'
                                THEN '/' || entry.relative_path
                                ELSE $3 || '/' || entry.relative_path
                            END AS path,
                            block.first_line, block.body
                     FROM pgos_private.all_content_blocks block
                     JOIN pgos_private.zone_entries entry
                       ON entry.content_object = block.object_id
                      AND entry.volume_id = $1
                      AND entry.zone_id = $2
                     WHERE block.volume_id = $1
                       AND entry.kind = 1
                       AND (block.segment_id IS NULL
                            OR block.segment_id = ANY($7::uuid[]))
                       AND ($4 = '' OR entry.relative_path = $4
                            OR starts_with(entry.relative_path, $4 || '/'))
                       AND (cardinality($6::text[]) = 0 OR EXISTS (
                           SELECT 1 FROM unnest($6::text[]) suffix
                           WHERE right(entry.name, length(suffix)) = suffix
                       ))
                       AND strpos(block.body, $5) > 0
                     ORDER BY (CASE WHEN $3 = '/'
                                    THEN '/' || entry.relative_path
                                    ELSE $3 || '/' || entry.relative_path
                               END) COLLATE \"C\", block.ordinal",
                )
                .bind::<SqlUuid, _>(volume)
                .bind::<BigInt, _>(scope.zone_id)
                .bind::<Text, _>(&scope.zone_path)
                .bind::<Text, _>(&scope.relative_path)
                .bind::<Text, _>(literal)
                .bind::<Array<Text>, _>(file_suffixes)
                .bind::<Array<SqlUuid>, _>(&scope.segment_ids)
                .load_iter::<PathBlockRow, PgRowByRowLoadingMode>(&mut connection)?;
                return stream_path_block_rows(rows, output);
            }
        }
        let needles = literal_patterns(literals);
        let rows = diesel::sql_query(
            "SELECT path, first_line, body FROM pgos.search_candidate_blocks($1, $2, $3, $4)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(target)
        .bind::<Nullable<Array<Text>>, _>(needles)
        .bind::<Array<Text>, _>(file_suffixes)
        .load_iter::<PathBlockRow, PgRowByRowLoadingMode>(&mut connection)?;
        stream_path_block_rows(rows, output)
    }

    /// Stream only lines which can match a required literal. The downstream
    /// GNU matcher still decides whether each candidate is an actual match.
    pub fn candidate_text(
        &self,
        volume: Uuid,
        target: &str,
        literals: Option<&[String]>,
        output: impl FnMut(&[u8]) -> Result<()>,
    ) -> Result<()> {
        self.candidate_word_text(volume, target, literals, None, None, output)
    }

    pub fn candidate_word_text(
        &self,
        volume: Uuid,
        target: &str,
        literals: Option<&[String]>,
        required_word: Option<&str>,
        minimum_ascii_letters: Option<u32>,
        output: impl FnMut(&[u8]) -> Result<()>,
    ) -> Result<()> {
        let target = path::normalize(target)?;
        let needles = literal_patterns(literals);
        let mut connection = self.connection()?;
        if let Some(needle) = needles.as_ref().filter(|values| values.len() == 1) {
            if literals.is_some_and(|values| values[0].len() <= 3) {
                let rows = diesel::sql_query(
                    "SELECT block.first_line, hits.body
                     FROM pgos_private.all_content_blocks block
                     CROSS JOIN LATERAL (
                         SELECT string_agg(line.body || E'\\n', '' ORDER BY line.number) AS body
                         FROM string_to_table(block.body, E'\\n')
                              WITH ORDINALITY AS line(body, number)
                         WHERE line.body LIKE $3
                     ) hits
                     WHERE block.volume_id = $1
                       AND block.object_id = (
                         SELECT object_id FROM pgos_private.file_content($1, $2)
                     )
                       AND block.body LIKE $3
                       AND hits.body IS NOT NULL
                     ORDER BY block.ordinal",
                )
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(&target)
                .bind::<Text, _>(&needle[0])
                .load_iter::<BlockRow, PgRowByRowLoadingMode>(&mut connection)?;
                return stream_candidate_rows(rows, literals, output);
            }
            let rows = diesel::sql_query(
                "SELECT first_line, body FROM pgos.candidate_file_literal_text($1, $2, $3)",
            )
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(&target)
            .bind::<Text, _>(&needle[0])
            .load_iter::<BlockRow, PgRowByRowLoadingMode>(&mut connection)?;
            return stream_candidate_rows(rows, literals, output);
        }
        if needles.is_none()
            && let Some(minimum) = minimum_ascii_letters
        {
            let rows = diesel::sql_query(
                "SELECT first_line, body FROM pgos.candidate_file_ascii_text($1, $2, $3)",
            )
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(&target)
            .bind::<Integer, _>(i32::try_from(minimum)?)
            .load_iter::<BlockRow, PgRowByRowLoadingMode>(&mut connection)?;
            return stream_candidate_rows(rows, literals, output);
        }
        let rows = diesel::sql_query(
            "SELECT first_line, body FROM pgos.candidate_indexed_lines($1, $2, $3, $4, $5, $6)",
        )
        .bind::<SqlUuid, _>(volume)
        .bind::<Text, _>(target)
        .bind::<Nullable<Array<Text>>, _>(needles)
        .bind::<Nullable<Text>, _>(Option::<String>::None)
        .bind::<Nullable<Text>, _>(required_word)
        .bind::<Nullable<Integer>, _>(minimum_ascii_letters.map(i32::try_from).transpose()?)
        .load_iter::<BlockRow, PgRowByRowLoadingMode>(&mut connection)?;
        stream_candidate_rows(rows, literals, output)
    }

    pub fn read_range(
        &self,
        volume: Uuid,
        target: &str,
        offset: u64,
        length: u32,
    ) -> Result<Vec<u8>> {
        let target = path::normalize(target)?;
        let mut connection = self.connection()?;
        let row: DataRow = diesel::sql_query("SELECT pgos.read_range($1, $2, $3, $4) AS data")
            .bind::<SqlUuid, _>(volume)
            .bind::<Text, _>(target)
            .bind::<BigInt, _>(i64::try_from(offset)?)
            .bind::<Integer, _>(i32::try_from(length)?)
            .get_result(&mut connection)?;
        Ok(row.data)
    }

    pub fn grep_file(
        &self,
        volume: Uuid,
        target: &str,
        pattern: &str,
        line_number: bool,
        mut output: impl FnMut(&[u8]) -> Result<()>,
    ) -> Result<bool> {
        let mut matcher = crate::core::search::BlockMatcher::new(pattern, line_number)?;
        let mut any_match = false;
        self.text_blocks(volume, target, |first_line, text| {
            let (data, found) = matcher.search(first_line, text)?;
            any_match |= found;
            for frame in data.chunks(64 * 1024) {
                output(frame)?;
            }
            Ok(())
        })?;
        Ok(any_match)
    }

    /// Import UTF-8 text atomically, with line-aligned blocks. Invalid UTF-8,
    /// NUL bytes, and oversized lines abort the transaction without publication.
    pub fn import_text(&self, volume: Uuid, target: &str, reader: impl BufRead) -> Result<i64> {
        use content_segment::dsl;
        let target = path::normalize(target)?;
        let object = Uuid::new_v4();
        let segment = Uuid::new_v4();
        let reader = RefCell::new(reader);
        let total = RefCell::new(0_i64);
        let mut connection = self.connection()?;
        connection.transaction::<_, anyhow::Error, _>(|connection| {
            diesel::sql_query("SELECT pgos_private.prepare_content_segment($1, $2)")
                .bind::<SqlUuid, _>(volume)
                .bind::<SqlUuid, _>(segment)
                .execute(connection)?;
            diesel::sql_query(
                "INSERT INTO pgos_private.content_objects(id, volume_id, segment_id)
                 VALUES ($1, $2, $3)",
            )
            .bind::<SqlUuid, _>(object)
            .bind::<SqlUuid, _>(volume)
            .bind::<SqlUuid, _>(segment)
            .execute(connection)?;
            let copy = diesel::copy_from(content_segment::table)
                .from_raw_data(
                    (
                        dsl::segment_id,
                        dsl::object_id,
                        dsl::volume_id,
                        dsl::ordinal,
                        dsl::byte_offset,
                        dsl::first_line,
                        dsl::body,
                    ),
                    |sink| {
                        write_blocks(sink, &mut *reader.borrow_mut(), segment, object, volume)
                            .map(|bytes| *total.borrow_mut() = bytes)
                            .map_err(|error| {
                                diesel::result::Error::SerializationError(
                                    error.into_boxed_dyn_error(),
                                )
                            })
                    },
                )
                .with_format(CopyFormat::Binary);
            diesel::prelude::ExecuteCopyFromDsl::execute(copy, connection)?;
            diesel::sql_query("SELECT pgos_private.publish_content_segment($1, $2)")
                .bind::<SqlUuid, _>(volume)
                .bind::<SqlUuid, _>(segment)
                .execute(connection)?;
            let row: CountRow =
                diesel::sql_query("SELECT pgos.publish_content($1, $2, $3, $4) AS value")
                    .bind::<SqlUuid, _>(volume)
                    .bind::<Text, _>(&target)
                    .bind::<SqlUuid, _>(object)
                    .bind::<BigInt, _>(*total.borrow())
                    .get_result(connection)?;
            Ok(row.value)
        })
    }

    /// Stream a large file in storage order under one SQL statement snapshot.
    pub fn text_blocks(
        &self,
        volume: Uuid,
        target: &str,
        mut consume: impl FnMut(i64, &str) -> Result<()>,
    ) -> Result<()> {
        self.filtered_text_blocks(volume, target, None, &mut consume)
    }

    pub fn filtered_text_blocks(
        &self,
        volume: Uuid,
        target: &str,
        literals: Option<&[String]>,
        mut consume: impl FnMut(i64, &str) -> Result<()>,
    ) -> Result<()> {
        let target = path::normalize(target)?;
        let needles = literal_patterns(literals);
        let mut connection = self.connection()?;
        let rows =
            diesel::sql_query("SELECT first_line, body FROM pgos.search_file_blocks($1, $2, $3)")
                .bind::<SqlUuid, _>(volume)
                .bind::<Text, _>(&target)
                .bind::<Nullable<Array<Text>>, _>(needles)
                .load_iter::<BlockRow, PgRowByRowLoadingMode>(&mut connection)?;
        for row in rows {
            let row = row?;
            consume(row.first_line, &row.body)?;
        }
        Ok(())
    }
}

fn stream_path_block_rows(
    rows: impl Iterator<Item = diesel::QueryResult<PathBlockRow>>,
    mut output: impl FnMut(&str, i64, &str) -> Result<()>,
) -> Result<()> {
    for row in rows {
        let row = row?;
        output(&row.path, row.first_line, &row.body)?;
    }
    Ok(())
}

fn stream_candidate_rows(
    rows: impl Iterator<Item = diesel::QueryResult<BlockRow>>,
    literals: Option<&[String]>,
    mut output: impl FnMut(&[u8]) -> Result<()>,
) -> Result<()> {
    let mut literal_matcher = literals
        .filter(|values| !values.is_empty())
        .map(crate::core::search::BlockMatcher::literals)
        .transpose()?;
    for row in rows {
        let row = row?;
        let selected = if let Some(matcher) = &mut literal_matcher {
            matcher.search(row.first_line, &row.body)?.0
        } else {
            row.body.into_bytes()
        };
        for frame in selected.chunks(64 * 1024) {
            output(frame)?;
        }
    }
    Ok(())
}

fn literal_patterns(literals: Option<&[String]>) -> Option<Vec<String>> {
    literals.map(|values| {
        values
            .iter()
            .map(|value| {
                format!(
                    "%{}%",
                    value
                        .replace('\\', "\\\\")
                        .replace('%', "\\%")
                        .replace('_', "\\_")
                )
            })
            .collect()
    })
}

fn field(sink: &mut (impl Write + ?Sized), value: &[u8]) -> Result<()> {
    sink.write_all(&i32::try_from(value.len())?.to_be_bytes())?;
    sink.write_all(value)?;
    Ok(())
}

fn write_blocks(
    sink: &mut (impl Write + ?Sized),
    reader: &mut impl BufRead,
    segment: Uuid,
    object: Uuid,
    volume: Uuid,
) -> Result<i64> {
    // PostgreSQL's documented binary COPY header and per-field lengths.
    sink.write_all(b"PGCOPY\n\xff\r\n\0\0\0\0\0\0\0\0\0")?;
    let mut block = Vec::with_capacity(BLOCK_BYTES);
    let mut ordinal = 0_i64;
    let mut offset = 0_i64;
    let mut first_line = 1_i64;
    loop {
        block.clear();
        let mut lines = 0_i64;
        while block.len() < BLOCK_BYTES {
            // Take bounds allocation even if the input contains no newline.
            let read = std::io::Read::take(&mut *reader, (MAX_LINE_BYTES + 1) as u64)
                .read_until(b'\n', &mut block)?;
            anyhow::ensure!(read <= MAX_LINE_BYTES, "text line exceeds 16 MiB");
            if read == 0 {
                break;
            }
            lines += 1;
        }
        if block.is_empty() {
            break;
        }
        std::str::from_utf8(&block).context("large text file is not UTF-8")?;
        anyhow::ensure!(!block.contains(&0), "large text file contains NUL");
        sink.write_all(&7_i16.to_be_bytes())?;
        field(sink, segment.as_bytes())?;
        field(sink, object.as_bytes())?;
        field(sink, volume.as_bytes())?;
        field(sink, &ordinal.to_be_bytes())?;
        field(sink, &offset.to_be_bytes())?;
        field(sink, &first_line.to_be_bytes())?;
        field(sink, &block)?;
        ordinal += 1;
        offset += i64::try_from(block.len())?;
        first_line += lines;
    }
    sink.write_all(&(-1_i16).to_be_bytes())?;
    Ok(offset)
}
