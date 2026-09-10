-- PostgreOS initial schema.
-- The public API is in `pgos`. Physical storage is in `pgos_private`.



-- Dumped from database version 16.15 (Debian 16.15-1.pgdg12+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg12+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgos; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS pgos;


--
-- Name: pgos_private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS pgos_private;


--
-- Name: apply_import(text, uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.apply_import(destination_path text, batch uuid) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.apply_import(pgos.current_volume(), destination_path, batch)
$$;


--
-- Name: apply_import(uuid, text, uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.apply_import(target_volume uuid, destination_path text, batch uuid) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    imported bigint;
    location record;
BEGIN
    imported := pgos.apply_import_inline(
        target_volume, destination_path, batch
    );
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, destination_path);
    PERFORM pgos_private.blockize_zone_segment(
        target_volume, location.zone_id
    );
    RETURN imported;
END
$$;


--
-- Name: apply_import_inline(uuid, text, uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.apply_import_inline(target_volume uuid, destination_path text, batch uuid) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $_$
DECLARE
    clean_destination text := pgos_private.assert_path(destination_path);
    clean_destination_parent text := pgos_private.parent_of(clean_destination);
    parent_location record;
    root_entry record;
    new_zone_id bigint;
    destination_relative text;
    imported_count bigint;
BEGIN
    IF to_regclass('pg_temp.pgos_import_staging') IS NULL
       OR to_regclass('pg_temp.pgos_import_context') IS NULL THEN
        RAISE EXCEPTION 'no import is active on this connection' USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_temp.pgos_import_context context
        WHERE context.batch_id = batch AND context.volume_id = target_volume
          AND context.destination = clean_destination
    ) THEN
        RAISE EXCEPTION 'the import context does not match' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO root_entry
    FROM pg_temp.pgos_import_staging staged
    WHERE staged.batch_id = batch AND staged.relative_path = '';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'the import batch has no root entry' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_temp.pgos_import_staging staged
        WHERE staged.batch_id = batch AND staged.relative_path <> '' AND (
            staged.relative_path !~ '^[^/]+(/[^/]+)*$'
            OR staged.relative_path ~ '(^|/)\.\.?(/|$)'
        )
    ) THEN
        RAISE EXCEPTION 'the import batch contains an invalid relative path'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_temp.pgos_import_staging child
        WHERE child.batch_id = batch AND child.relative_path <> ''
          AND NOT EXISTS (
              SELECT 1 FROM pg_temp.pgos_import_staging parent
              WHERE parent.batch_id = child.batch_id
                AND parent.relative_path = pgos_private.relative_parent(child.relative_path)
                AND parent.kind = 2
          )
    ) THEN
        RAISE EXCEPTION 'the import batch contains a missing or non-directory parent'
            USING ERRCODE = '22023';
    END IF;
    IF pgos_private.kind_of(target_volume, clean_destination_parent) IS DISTINCT FROM 2
       OR pgos_private.kind_of(target_volume, clean_destination) IS NOT NULL THEN
        RAISE EXCEPTION 'the import destination is not available' USING ERRCODE = '23505';
    END IF;
    SELECT * INTO STRICT parent_location
    FROM pgos_private.locate_zone(target_volume, clean_destination_parent);

    IF root_entry.kind = 2 THEN
        INSERT INTO pgos_private.zones (
            volume_id, path, parent_zone_id, parent_path, name,
            mode, uid, gid, atime, mtime, ctime
        ) VALUES (
            target_volume, clean_destination, parent_location.zone_id,
            parent_location.relative_path, pgos_private.name_of(clean_destination),
            root_entry.mode, root_entry.uid, root_entry.gid,
            to_timestamp(root_entry.mtime_seconds::double precision
                         + root_entry.mtime_nanoseconds::double precision / 1000000000),
            to_timestamp(root_entry.mtime_seconds::double precision
                         + root_entry.mtime_nanoseconds::double precision / 1000000000),
            clock_timestamp()
        ) RETURNING id INTO new_zone_id;

        INSERT INTO pgos_private.zone_entries (
            volume_id, zone_id, relative_path, parent_path, name, kind,
            text_content, binary_content, mode, uid, gid, size,
            atime, mtime, ctime, link_target
        )
        SELECT target_volume, new_zone_id, staged.relative_path,
               pgos_private.relative_parent(staged.relative_path),
               pgos_private.relative_name(staged.relative_path), staged.kind,
               CASE WHEN staged.kind = 1 THEN decoded.value ELSE NULL END,
               CASE WHEN staged.kind = 1 AND decoded.value IS NULL THEN staged.content ELSE NULL END,
               staged.mode, staged.uid, staged.gid,
               CASE WHEN staged.kind = 1 THEN octet_length(staged.content) ELSE 0 END,
               to_timestamp(staged.mtime_seconds::double precision
                            + staged.mtime_nanoseconds::double precision / 1000000000),
               to_timestamp(staged.mtime_seconds::double precision
                            + staged.mtime_nanoseconds::double precision / 1000000000),
               clock_timestamp(),
               CASE WHEN staged.kind = 3 THEN staged.link_target ELSE NULL END
        FROM pg_temp.pgos_import_staging staged
        CROSS JOIN LATERAL (
            SELECT pgos_private.utf8_or_null(staged.content) AS value
        ) decoded
        WHERE staged.batch_id = batch AND staged.relative_path <> '';
    ELSE
        destination_relative := CASE
            WHEN parent_location.relative_path = '' THEN pgos_private.name_of(clean_destination)
            ELSE parent_location.relative_path || '/' || pgos_private.name_of(clean_destination)
        END;
        INSERT INTO pgos_private.zone_entries (
            volume_id, zone_id, relative_path, parent_path, name, kind,
            text_content, binary_content, mode, uid, gid, size,
            atime, mtime, ctime, link_target
        ) VALUES (
            target_volume, parent_location.zone_id, destination_relative,
            parent_location.relative_path, pgos_private.name_of(clean_destination), root_entry.kind,
            CASE WHEN root_entry.kind = 1 THEN pgos_private.utf8_or_null(root_entry.content) END,
            CASE WHEN root_entry.kind = 1 AND pgos_private.utf8_or_null(root_entry.content) IS NULL
                 THEN root_entry.content END,
            root_entry.mode, root_entry.uid, root_entry.gid,
            CASE WHEN root_entry.kind = 1 THEN octet_length(root_entry.content) ELSE 0 END,
            to_timestamp(root_entry.mtime_seconds::double precision
                         + root_entry.mtime_nanoseconds::double precision / 1000000000),
            to_timestamp(root_entry.mtime_seconds::double precision
                         + root_entry.mtime_nanoseconds::double precision / 1000000000),
            clock_timestamp(), CASE WHEN root_entry.kind = 3 THEN root_entry.link_target END
        );
    END IF;
    SELECT count(*) INTO imported_count
    FROM pg_temp.pgos_import_staging WHERE batch_id = batch;
    RETURN imported_count;
END
$_$;


--
-- Name: candidate_file_ascii_text(uuid, text, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.candidate_file_ascii_text(target_volume uuid, target_path text, minimum_letters integer) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    WITH candidate_blocks AS (
        SELECT block.ordinal, block.first_line, block.body
        FROM pgos_private.file_content(target_volume, target_path) file
        JOIN pgos_private.all_content_blocks block ON block.object_id = file.object_id
        WHERE block.volume_id = target_volume
          AND block.body COLLATE "C" ~ format('[A-Za-z]{%s}', minimum_letters)

        UNION ALL

        SELECT 0::bigint, 1::bigint, file.inline_text
        FROM pgos_private.file_content(target_volume, target_path) file
        WHERE file.object_id IS NULL
          AND file.inline_text COLLATE "C" ~ format(
              '[A-Za-z]{%s}', minimum_letters
          )
    )
    SELECT block.first_line, hits.body
    FROM candidate_blocks block
    CROSS JOIN LATERAL (
        SELECT string_agg(line.body || E'\n', '' ORDER BY line.number) AS body
        FROM string_to_table(block.body, E'\n')
             WITH ORDINALITY AS line(body, number)
        WHERE line.body COLLATE "C" ~ format(
            '[A-Za-z]{%s}', minimum_letters
        )
    ) hits
    WHERE hits.body IS NOT NULL
    ORDER BY block.ordinal
$$;


--
-- Name: candidate_file_literal_text(uuid, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.candidate_file_literal_text(target_volume uuid, target_path text, needle text) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    WITH candidate_blocks AS (
        SELECT block.ordinal, block.first_line, block.body
        FROM pgos_private.file_content(target_volume, target_path) file
        JOIN pgos_private.all_content_blocks block ON block.object_id = file.object_id
        WHERE block.volume_id = target_volume
          AND block.body LIKE needle

        UNION ALL

        SELECT 0::bigint, 1::bigint, file.inline_text
        FROM pgos_private.file_content(target_volume, target_path) file
        WHERE file.object_id IS NULL AND file.inline_text LIKE needle
    )
    SELECT block.first_line, hits.body
    FROM candidate_blocks block
    CROSS JOIN LATERAL (
        SELECT string_agg(line.body || E'\n', '' ORDER BY line.number) AS body
        FROM string_to_table(block.body, E'\n')
             WITH ORDINALITY AS line(body, number)
        WHERE line.body LIKE needle
    ) hits
    WHERE hits.body IS NOT NULL
    ORDER BY block.ordinal
$$;


--
-- Name: candidate_indexed_lines(uuid, text, text[], text, text, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.candidate_indexed_lines(target_volume uuid, target_path text, needles text[], line_expression text, required_word text, minimum_ascii_letters integer) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
BEGIN
    IF cardinality(needles) = 1 THEN
        RETURN QUERY
        WITH matching_blocks AS MATERIALIZED (
            SELECT block.object_id, block.ordinal, block.first_line, block.body
            FROM pgos_private.all_content_blocks block
            WHERE block.volume_id = target_volume
              AND block.body LIKE needles[1]
        )
        SELECT candidate.first_line + line.number - 1,
               line.body || E'\n'
        FROM pgos_private.file_content(target_volume, target_path) file
        CROSS JOIN LATERAL (
            (SELECT block.ordinal, block.first_line, block.body
             FROM matching_blocks block
             WHERE block.object_id = file.object_id
             ORDER BY block.ordinal)
            UNION ALL
            SELECT 0::bigint, 1::bigint, file.inline_text
            WHERE file.object_id IS NULL
              AND file.inline_text LIKE needles[1]
        ) candidate
        CROSS JOIN LATERAL string_to_table(candidate.body, E'\n')
            WITH ORDINALITY AS line(body, number)
        WHERE line.body LIKE needles[1]
        ORDER BY candidate.ordinal, line.number;
        RETURN;
    END IF;

    -- Some expressions guarantee a long ASCII-letter run but contain no
    -- fixed literal. Filter their lines in PostgreSQL to avoid transferring
    -- the complete large file. GNU grep still verifies the candidate stream.
    IF needles IS NULL AND minimum_ascii_letters IS NOT NULL THEN
        RETURN QUERY
        SELECT candidate.first_line + line.number - 1,
               line.body || E'\n'
        FROM pgos_private.file_content(target_volume, target_path) file
        CROSS JOIN LATERAL (
            (SELECT block.ordinal, block.first_line, block.body
             FROM pgos_private.all_content_blocks block
             WHERE block.object_id = file.object_id
               AND block.volume_id = target_volume
               AND block.body COLLATE "C" ~ format(
                   '[A-Za-z]{%s}', minimum_ascii_letters
               )
             ORDER BY block.ordinal)
            UNION ALL
            SELECT 0::bigint, 1::bigint, file.inline_text
            WHERE file.object_id IS NULL
              AND file.inline_text COLLATE "C" ~ format(
                  '[A-Za-z]{%s}', minimum_ascii_letters
              )
        ) candidate
        CROSS JOIN LATERAL string_to_table(candidate.body, E'\n')
            WITH ORDINALITY AS line(body, number)
        WHERE line.body COLLATE "C" ~ format(
            '[A-Za-z]{%s}', minimum_ascii_letters
        )
        ORDER BY candidate.ordinal, line.number;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT candidate.first_line, candidate.body
    FROM pgos_private.file_content(target_volume, target_path) file
    CROSS JOIN LATERAL (
        (SELECT block.ordinal, block.first_line, block.body
         FROM pgos_private.matching_content_blocks(target_volume, needles) block
         WHERE block.object_id = file.object_id
         ORDER BY block.ordinal)
        UNION ALL
        SELECT 0::bigint, 1::bigint, file.inline_text
        WHERE file.object_id IS NULL
          AND (needles IS NULL OR EXISTS (
              SELECT 1 FROM unnest(needles) needle
              WHERE file.inline_text LIKE needle
          ))
    ) candidate
    ORDER BY candidate.ordinal;
END
$$;


--
-- Name: candidate_lines(uuid, text, text[], text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.candidate_lines(target_volume uuid, target_path text, needles text[], line_expression text) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    SELECT block.first_line,
        CASE WHEN needles IS NULL THEN block.body ELSE coalesce((
            SELECT string_agg(hit.parts[1] || E'\n', '' ORDER BY hit.position)
            FROM regexp_matches(block.body COLLATE "C", line_expression, 'g')
                 WITH ORDINALITY AS hit(parts, position)
        ), '') END
    FROM pgos.search_file_blocks(target_volume, target_path, needles) block
$$;


--
-- Name: candidate_word_lines(uuid, text, text[], text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.candidate_word_lines(target_volume uuid, target_path text, needles text[], line_expression text, required_word text) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    SELECT block.first_line, coalesce((
        SELECT string_agg(hit.parts[1] || E'\n', '' ORDER BY hit.position)
        FROM regexp_matches(block.body COLLATE "C", line_expression, 'g')
             WITH ORDINALITY AS hit(parts, position)
    ), '')
    FROM pgos_private.file_content(target_volume, target_path) file
    CROSS JOIN LATERAL (
        (SELECT b.first_line, b.body
         FROM pgos_private.content_block_terms terms
         JOIN pgos_private.all_content_blocks b
           ON b.object_id = terms.object_id AND b.ordinal = terms.ordinal
         WHERE required_word IS NOT NULL AND terms.object_id = file.object_id
           AND terms.terms @@ plainto_tsquery('simple', required_word)
         ORDER BY b.ordinal)
        UNION ALL
        SELECT 1::bigint, file.inline_text
        WHERE required_word IS NOT NULL AND file.object_id IS NULL
          AND (needles IS NULL OR file.inline_text LIKE ANY(needles))
    ) block
    UNION ALL
    SELECT * FROM pgos.candidate_lines(target_volume, target_path, needles, line_expression)
    WHERE required_word IS NULL
$$;


--
-- Name: capabilities(); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.capabilities() RETURNS TABLE(api_version integer, feature text)
    LANGUAGE sql STABLE
    AS $$
    SELECT 1, feature
    FROM unnest(ARRAY[
        'read', 'write', 'list', 'walk', 'mkdir',
        'copy', 'move', 'remove', 'literal-search', 'batch-import'
    ]) AS feature
$$;


--
-- Name: cat_command_files(uuid, text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.cat_command_files(target_volume uuid, target_paths text[]) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    requested_count bigint := cardinality(target_paths);
    matched_count bigint;
    result bytea;
BEGIN
    IF requested_count = 0 THEN RETURN ''::bytea; END IF;

    WITH requested AS MATERIALIZED (
        SELECT input.path, input.ordinality,
               pgos_private.parent_of(input.path) AS parent_path,
               pgos_private.name_of(input.path) AS name
        FROM unnest(target_paths) WITH ORDINALITY AS input(path, ordinality)
    ), parents AS MATERIALIZED (
        SELECT DISTINCT requested.parent_path FROM requested
    ), locations AS MATERIALIZED (
        SELECT parents.parent_path, location.*
        FROM parents
        CROSS JOIN LATERAL pgos_private.locate_zone(
            target_volume, parents.parent_path
        ) location
    ), files AS (
        SELECT requested.ordinality,
               CASE
                   WHEN entry.content_object IS NOT NULL THEN
                       pgos_private.entry_bytes(
                           entry.text_content, entry.binary_content,
                           entry.content_object
                       )
                   WHEN entry.text_content IS NOT NULL THEN
                       convert_to(entry.text_content, 'UTF8')
                   ELSE entry.binary_content
               END AS data
        FROM requested
        JOIN locations ON locations.parent_path = requested.parent_path
        LEFT JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume
         AND entry.zone_id = locations.zone_id
         AND entry.relative_path = CASE
             WHEN locations.relative_path = '' THEN requested.name
             ELSE locations.relative_path || '/' || requested.name
         END
         AND entry.kind = 1
    )
    SELECT count(data), string_agg(data, ''::bytea ORDER BY ordinality)
    INTO matched_count, result
    FROM files;
    IF matched_count <> requested_count THEN
        RAISE EXCEPTION 'a path does not exist or is not a regular file'
            USING ERRCODE = 'P0002';
    END IF;
    RETURN result;
END
$$;


--
-- Name: cat_files(text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.cat_files(target_paths text[]) RETURNS bytea
    LANGUAGE sql STABLE
    AS $$
    SELECT pgos.cat_files(pgos.current_volume(), target_paths)
$$;


--
-- Name: cat_files(uuid, text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.cat_files(target_volume uuid, target_paths text[]) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    requested_count bigint := cardinality(target_paths);
    matched_count bigint;
    result bytea;
BEGIN
    IF requested_count = 0 THEN RETURN ''::bytea; END IF;

    SELECT count(data), string_agg(data, ''::bytea ORDER BY ordinality)
    INTO matched_count, result
    FROM pgos.read_files(target_volume, target_paths);
    IF matched_count <> requested_count THEN
        RAISE EXCEPTION 'a path does not exist or is not a regular file'
            USING ERRCODE = 'P0002';
    END IF;
    RETURN result;
END
$$;


--
-- Name: copy(text, text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.copy(source_path text, destination_path text, recursive boolean DEFAULT false) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.copy(pgos.current_volume(), source_path, destination_path, recursive)
$$;


--
-- Name: copy(uuid, text, text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.copy(target_volume uuid, source_path text, destination_path text, recursive boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_source text := pgos_private.assert_path(source_path);
    clean_destination text := pgos_private.assert_path(destination_path);
    source_location record;
    destination_parent_location record;
    source_entry record;
    new_zone_id bigint;
    destination_relative text;
    inserted_count bigint;
BEGIN
    IF clean_source = '/' OR clean_destination = clean_source
       OR clean_destination LIKE clean_source || '/%' THEN
        RAISE EXCEPTION 'cannot copy this path' USING ERRCODE = '22023';
    END IF;
    IF pgos_private.kind_of(target_volume, clean_destination) IS NOT NULL THEN
        RAISE EXCEPTION 'destination exists: %', clean_destination USING ERRCODE = '23505';
    END IF;
    IF pgos_private.kind_of(target_volume, pgos_private.parent_of(clean_destination)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'destination parent does not exist: %', clean_destination
            USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO STRICT source_location
    FROM pgos_private.locate_zone(target_volume, clean_source);
    SELECT * INTO STRICT destination_parent_location
    FROM pgos_private.locate_zone(target_volume, pgos_private.parent_of(clean_destination));

    IF source_location.relative_path = '' THEN
        IF NOT recursive THEN
            RAISE EXCEPTION 'omitting directory: %', clean_source USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM pgos_private.zones z
            WHERE z.volume_id = target_volume AND z.path LIKE clean_source || '/%'
        ) THEN
            RAISE EXCEPTION 'copying nested zones is not implemented' USING ERRCODE = '0A000';
        END IF;
        INSERT INTO pgos_private.zones (
            volume_id, path, parent_zone_id, parent_path, name,
            mode, uid, gid, atime, mtime, ctime
        )
        SELECT target_volume, clean_destination, destination_parent_location.zone_id,
               destination_parent_location.relative_path,
               pgos_private.name_of(clean_destination), z.mode, z.uid, z.gid,
               z.atime, z.mtime, clock_timestamp()
        FROM pgos_private.zones z WHERE z.id = source_location.zone_id
        RETURNING id INTO new_zone_id;

        INSERT INTO pgos_private.zone_entries (
            volume_id, zone_id, relative_path, parent_path, name, kind,
            text_content, binary_content, content_object, mode, uid, gid, size,
            atime, mtime, ctime, link_target, generation
        )
        SELECT target_volume, new_zone_id, relative_path, parent_path, name, kind,
               text_content, binary_content, content_object, mode, uid, gid, size,
               atime, mtime, clock_timestamp(), link_target, 1
        FROM pgos_private.zone_entries
        WHERE volume_id = target_volume AND zone_id = source_location.zone_id;
        GET DIAGNOSTICS inserted_count = ROW_COUNT;
        RETURN inserted_count + 1;
    END IF;

    SELECT * INTO source_entry
    FROM pgos_private.zone_entries entry
    WHERE entry.volume_id = target_volume AND entry.zone_id = source_location.zone_id
      AND entry.relative_path = source_location.relative_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'source does not exist: %', clean_source USING ERRCODE = 'P0002';
    END IF;
    IF source_entry.kind = 2 AND NOT recursive THEN
        RAISE EXCEPTION 'omitting directory: %', clean_source USING ERRCODE = '22023';
    END IF;
    IF source_entry.kind = 2 AND EXISTS (
        SELECT 1 FROM pgos_private.zones z
        WHERE z.volume_id = target_volume AND z.path LIKE clean_source || '/%'
    ) THEN
        RAISE EXCEPTION 'copying nested zones is not implemented' USING ERRCODE = '0A000';
    END IF;
    destination_relative := CASE
        WHEN destination_parent_location.relative_path = '' THEN pgos_private.name_of(clean_destination)
        ELSE destination_parent_location.relative_path || '/' || pgos_private.name_of(clean_destination)
    END;

    INSERT INTO pgos_private.zone_entries (
        volume_id, zone_id, relative_path, parent_path, name, kind,
        text_content, binary_content, content_object, mode, uid, gid, size,
        atime, mtime, ctime, link_target, generation
    )
    SELECT target_volume, destination_parent_location.zone_id,
           destination_relative || substr(entry.relative_path, length(source_location.relative_path) + 1),
           pgos_private.relative_parent(
               destination_relative || substr(entry.relative_path, length(source_location.relative_path) + 1)
           ),
           CASE WHEN entry.relative_path = source_location.relative_path
                THEN pgos_private.name_of(clean_destination) ELSE entry.name END,
           entry.kind, entry.text_content, entry.binary_content, entry.content_object,
           entry.mode, entry.uid, entry.gid, entry.size,
           entry.atime, entry.mtime, clock_timestamp(), entry.link_target, 1
    FROM pgos_private.zone_entries entry
    WHERE entry.volume_id = target_volume AND entry.zone_id = source_location.zone_id
      AND (entry.relative_path = source_location.relative_path
           OR (recursive AND entry.relative_path LIKE source_location.relative_path || '/%'));
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN inserted_count;
END
$$;


--
-- Name: create_volume(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.create_volume(volume_id uuid, volume_name text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO pgos_private.volumes (id, name) VALUES (volume_id, volume_name);
    INSERT INTO pgos_private.zones
        (volume_id, path, parent_zone_id, parent_path, name, mode)
    VALUES (volume_id, '/', NULL, NULL, '', 493);
    PERFORM pgos_private.prepare_content_volume(volume_id);
    RETURN volume_id;
END
$$;


--
-- Name: current_volume(); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.current_volume() RETURNS uuid
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    selected uuid;
BEGIN
    BEGIN
        selected := current_setting('pgos.volume_id', true)::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        selected := NULL;
    END;
    IF selected IS NULL OR NOT EXISTS (
        SELECT 1 FROM pgos_private.volumes WHERE id = selected
    ) THEN
        RAISE EXCEPTION 'no valid PostgreOS volume is selected' USING ERRCODE = '22023';
    END IF;
    RETURN selected;
END
$$;


--
-- Name: disk_usage(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.disk_usage(target_path text) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT pgos.disk_usage(pgos.current_volume(), target_path)
$$;


--
-- Name: disk_usage(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.disk_usage(target_volume uuid, target_path text) RETURNS bigint
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
    entry_kind smallint;
    entry_size bigint;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);
    IF location.relative_path <> '' THEN
        SELECT kind, size INTO entry_kind, entry_size
        FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND entry.relative_path = location.relative_path;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'path does not exist: %', clean_path USING ERRCODE = 'P0002';
        END IF;
        IF entry_kind = 1 THEN RETURN entry_size; END IF;
    END IF;

    RETURN (
        WITH selected_zones AS (
            SELECT z.id,
                   CASE WHEN z.id = location.zone_id THEN location.relative_path ELSE '' END AS relative_root
            FROM pgos_private.zones z
            WHERE z.volume_id = target_volume
              AND (z.id = location.zone_id OR clean_path = '/'
                   OR z.path = clean_path OR z.path LIKE clean_path || '/%')
        )
        SELECT COALESCE(sum(entry.size), 0)::bigint
        FROM selected_zones selected
        JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume AND entry.zone_id = selected.id
        WHERE entry.kind = 1
          AND (selected.relative_root = ''
               OR entry.relative_path LIKE selected.relative_root || '/%')
    );
END
$$;


--
-- Name: disk_usage_fast(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.disk_usage_fast(target_volume uuid, target_path text) RETURNS bigint
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
    total bigint;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);
    IF location.relative_path <> '' THEN
        RETURN pgos.disk_usage(target_volume, clean_path);
    END IF;

    SELECT COALESCE(sum(zone.file_bytes), 0)::bigint
    INTO total
    FROM pgos_private.zones zone
    WHERE zone.volume_id = target_volume
      AND (zone.path = clean_path OR zone.path LIKE clean_path || '/%');
    RETURN total;
END
$$;


--
-- Name: file_blocks(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.file_blocks(target_volume uuid, target_path text) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    SELECT block.first_line, block.body
    FROM pgos_private.file_content(target_volume, target_path) file
    CROSS JOIN LATERAL (
        (SELECT b.first_line, b.body FROM pgos_private.all_content_blocks b
         WHERE b.object_id = file.object_id ORDER BY b.ordinal)
        UNION ALL
        SELECT 1::bigint, file.inline_text WHERE file.object_id IS NULL
    ) block
$$;


--
-- Name: find_command_output(uuid, text, text, smallint, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_command_output(target_volume uuid, target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint, path_prefix text DEFAULT ''::text) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
    result bytea;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);

    IF kind_filter IN (1, 3) AND NOT EXISTS (
        SELECT 1 FROM pgos_private.zones zone
        WHERE zone.volume_id = target_volume AND zone.path LIKE clean_path || '/%'
    ) THEN
        SELECT convert_to(
            COALESCE(string_agg(
                path_prefix || pgos_private.absolute_path(
                    location.zone_path, entry.relative_path
                ), E'\n'
            ) || E'\n', ''),
            'UTF8'
        )
        INTO result
        FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND entry.kind = kind_filter
          AND (location.relative_path = ''
               OR entry.relative_path = location.relative_path
               OR entry.relative_path LIKE location.relative_path || '/%')
          AND (name_pattern IS NULL OR entry.name LIKE
               replace(replace(replace(replace(replace(
                   name_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
               ESCAPE '\');
        RETURN result;
    END IF;

    RETURN pgos.find_output(
        target_volume, clean_path, name_pattern, kind_filter, path_prefix
    );
END
$$;


--
-- Name: find_entries(text, text, smallint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_entries(target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.find_entries(
        pgos.current_volume(), target_path, name_pattern, kind_filter
    )
$$;


--
-- Name: find_entries(uuid, text, text, smallint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_entries(target_volume uuid, target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);

    RETURN QUERY
    WITH selected_zones AS (
        SELECT z.id, z.path,
               CASE WHEN z.id = location.zone_id THEN location.relative_path ELSE '' END AS relative_root
        FROM pgos_private.zones z
        WHERE z.volume_id = target_volume
          AND (z.id = location.zone_id OR clean_path = '/'
               OR z.path = clean_path OR z.path LIKE clean_path || '/%')
    ), found AS (
        SELECT z.id, z.path::text, z.name::text, 2::smallint AS kind,
               z.mode, z.uid, z.gid, 0::bigint AS size, z.mtime, z.generation
        FROM selected_zones selected
        JOIN pgos_private.zones z ON z.id = selected.id
        WHERE clean_path = '/' OR z.path = clean_path OR z.path LIKE clean_path || '/%'
        UNION ALL
        SELECT entry.id,
               pgos_private.absolute_path(selected.path, entry.relative_path),
               entry.name::text, entry.kind, entry.mode, entry.uid, entry.gid,
               entry.size, entry.mtime, entry.generation
        FROM selected_zones selected
        JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume AND entry.zone_id = selected.id
        WHERE selected.relative_root = ''
           OR entry.relative_path = selected.relative_root
           OR entry.relative_path LIKE selected.relative_root || '/%'
    )
    SELECT found.id, found.path, found.name, found.kind, found.mode,
           found.uid, found.gid, found.size, found.mtime, found.generation
    FROM found
    WHERE (kind_filter IS NULL OR found.kind = kind_filter)
      AND (name_pattern IS NULL OR found.name LIKE
           replace(replace(replace(replace(replace(
               name_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
           ESCAPE '\')
    ORDER BY found.path COLLATE "C";
END
$$;


--
-- Name: find_output(text, text, smallint, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_output(target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint, path_prefix text DEFAULT ''::text) RETURNS bytea
    LANGUAGE sql STABLE
    AS $$
    SELECT pgos.find_output(
        pgos.current_volume(), target_path, name_pattern, kind_filter, path_prefix
    )
$$;


--
-- Name: find_output(uuid, text, text, smallint, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_output(target_volume uuid, target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint, path_prefix text DEFAULT ''::text) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
    result bytea;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);

    IF kind_filter IN (1, 3) AND NOT EXISTS (
        SELECT 1 FROM pgos_private.zones zone
        WHERE zone.volume_id = target_volume AND zone.path LIKE clean_path || '/%'
    ) THEN
        SELECT convert_to(
            COALESCE(string_agg(path_prefix || ordered.path, E'\n') || E'\n', ''),
            'UTF8'
        )
        INTO result
        FROM (
            SELECT pgos_private.absolute_path(location.zone_path, entry.relative_path) AS path
            FROM pgos_private.zone_entries entry
            WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
              AND entry.kind = kind_filter
              AND (location.relative_path = ''
                   OR entry.relative_path = location.relative_path
                   OR entry.relative_path LIKE location.relative_path || '/%')
              AND (name_pattern IS NULL OR entry.name LIKE
                   replace(replace(replace(replace(replace(
                       name_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
                   ESCAPE '\')
            ORDER BY entry.relative_path
        ) ordered;
        RETURN result;
    END IF;

    SELECT convert_to(
        COALESCE(string_agg(path_prefix || found.path, E'\n'
                   ORDER BY found.path COLLATE "C") || E'\n', ''),
        'UTF8'
    )
    INTO result
    FROM (
        WITH selected_zones AS (
            SELECT zone.id, zone.path,
                   CASE WHEN zone.id = location.zone_id
                        THEN location.relative_path ELSE '' END AS relative_root
            FROM pgos_private.zones zone
            WHERE zone.volume_id = target_volume
              AND (zone.id = location.zone_id OR clean_path = '/'
                   OR zone.path = clean_path OR zone.path LIKE clean_path || '/%')
        ), candidates AS (
            SELECT zone.path::text AS path, zone.name::text AS name, 2::smallint AS kind
            FROM selected_zones selected
            JOIN pgos_private.zones zone ON zone.id = selected.id
            WHERE clean_path = '/' OR zone.path = clean_path OR zone.path LIKE clean_path || '/%'
            UNION ALL
            SELECT pgos_private.absolute_path(selected.path, entry.relative_path),
                   entry.name::text, entry.kind
            FROM selected_zones selected
            JOIN pgos_private.zone_entries entry
              ON entry.volume_id = target_volume AND entry.zone_id = selected.id
            WHERE selected.relative_root = ''
               OR entry.relative_path = selected.relative_root
               OR entry.relative_path LIKE selected.relative_root || '/%'
        )
        SELECT candidates.path
        FROM candidates
        WHERE (kind_filter IS NULL OR candidates.kind = kind_filter)
          AND (name_pattern IS NULL OR candidates.name LIKE
               replace(replace(replace(replace(replace(
                   name_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
               ESCAPE '\')
    ) found;
    RETURN result;
END
$$;


--
-- Name: find_paths(text, text, smallint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_paths(target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint) RETURNS TABLE(path text)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.find_paths(
        pgos.current_volume(), target_path, name_pattern, kind_filter
    )
$$;


--
-- Name: find_paths(uuid, text, text, smallint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.find_paths(target_volume uuid, target_path text, name_pattern text DEFAULT NULL::text, kind_filter smallint DEFAULT NULL::smallint) RETURNS TABLE(path text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);

    RETURN QUERY
    WITH selected_zones AS (
        SELECT z.id, z.path,
               CASE WHEN z.id = location.zone_id THEN location.relative_path ELSE '' END AS relative_root
        FROM pgos_private.zones z
        WHERE z.volume_id = target_volume
          AND (z.id = location.zone_id OR clean_path = '/'
               OR z.path = clean_path OR z.path LIKE clean_path || '/%')
    ),
    found AS (
        SELECT z.path::text AS path, z.name::text AS name, 2::smallint AS kind
        FROM selected_zones selected
        JOIN pgos_private.zones z ON z.id = selected.id
        WHERE clean_path = '/' OR z.path = clean_path OR z.path LIKE clean_path || '/%'
        UNION ALL
        SELECT pgos_private.absolute_path(selected.path, entry.relative_path),
               entry.name::text, entry.kind
        FROM selected_zones selected
        JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume AND entry.zone_id = selected.id
        WHERE selected.relative_root = ''
           OR entry.relative_path = selected.relative_root
           OR entry.relative_path LIKE selected.relative_root || '/%'
    )
    SELECT found.path
    FROM found
    WHERE (kind_filter IS NULL OR found.kind = kind_filter)
      AND (name_pattern IS NULL OR found.name LIKE
           replace(replace(replace(replace(replace(
               name_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
           ESCAPE '\')
    ORDER BY found.path COLLATE "C";
END
$$;


--
-- Name: inode(uuid, bigint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.inode(target_volume uuid, target_id bigint) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE sql STABLE
    AS $$
    SELECT z.id, z.path::text, z.name::text, 2::smallint, z.mode,
           z.uid, z.gid, 0::bigint, z.atime, z.mtime, z.ctime,
           z.generation, NULL::text
    FROM pgos_private.zones z
    WHERE z.volume_id = target_volume AND z.id = target_id
    UNION ALL
    SELECT e.id, pgos_private.absolute_path(z.path, e.relative_path),
           e.name::text, e.kind, e.mode, e.uid, e.gid, e.size,
           e.atime, e.mtime, e.ctime, e.generation, e.link_target
    FROM pgos_private.zone_entries e
    JOIN pgos_private.zones z ON z.id = e.zone_id
    WHERE e.volume_id = target_volume AND e.id = target_id
$$;


--
-- Name: list(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list(target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.list(pgos.current_volume(), target_path)
$$;


--
-- Name: list(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list(target_volume uuid, target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);

    IF location.relative_path <> '' AND NOT EXISTS (
        SELECT 1 FROM pgos_private.zone_entries e
        WHERE e.volume_id = target_volume AND e.zone_id = location.zone_id
          AND e.relative_path = location.relative_path AND e.kind = 2
    ) THEN
        RAISE EXCEPTION 'not a directory: %', target_path USING ERRCODE = '42809';
    END IF;

    RETURN QUERY
    SELECT listed.id, listed.path, listed.name, listed.kind, listed.mode,
           listed.uid, listed.gid, listed.size, listed.mtime, listed.generation
    FROM (
        SELECT child.id,
               pgos_private.absolute_path(location.zone_path, child.relative_path) AS path,
               child.name::text AS name, child.kind, child.mode, child.uid, child.gid,
               child.size, child.mtime, child.generation
        FROM pgos_private.zone_entries child
        WHERE child.volume_id = target_volume AND child.zone_id = location.zone_id
          AND child.parent_path = location.relative_path
        UNION ALL
        SELECT z.id, z.path::text, z.name::text, 2::smallint, z.mode, z.uid, z.gid,
               0::bigint, z.mtime, z.generation
        FROM pgos_private.zones z
        WHERE z.volume_id = target_volume AND z.parent_zone_id = location.zone_id
          AND z.parent_path = location.relative_path
    ) listed
    ORDER BY listed.name COLLATE "C";
END
$$;


--
-- Name: list_names(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list_names(target_path text) RETURNS TABLE(name text)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.list_names(pgos.current_volume(), target_path)
$$;


--
-- Name: list_names(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list_names(target_volume uuid, target_path text) RETURNS TABLE(name text)
    LANGUAGE sql STABLE
    AS $$
    SELECT listed.name FROM pgos.list(target_volume, target_path) listed
    ORDER BY listed.name COLLATE "C"
$$;


--
-- Name: list_output(text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list_output(target_path text, include_hidden boolean DEFAULT false) RETURNS bytea
    LANGUAGE sql STABLE
    AS $$
    SELECT pgos.list_output(
        pgos.current_volume(), target_path, include_hidden
    )
$$;


--
-- Name: list_output(uuid, text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.list_output(target_volume uuid, target_path text, include_hidden boolean DEFAULT false) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    location record;
    result bytea;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);
    IF location.relative_path <> '' AND NOT EXISTS (
        SELECT 1 FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND entry.relative_path = location.relative_path AND entry.kind = 2
    ) THEN
        RAISE EXCEPTION 'not a directory: %', target_path USING ERRCODE = '42809';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pgos_private.zones zone
        WHERE zone.volume_id = target_volume AND zone.parent_zone_id = location.zone_id
          AND zone.parent_path = location.relative_path
    ) THEN
        SELECT convert_to(
            COALESCE(string_agg(ordered.name, E'\n') || E'\n', ''),
            'UTF8'
        )
        INTO result
        FROM (
            SELECT entry.name::text AS name
            FROM pgos_private.zone_entries entry
            WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
              AND entry.parent_path = location.relative_path
              AND (include_hidden OR entry.name !~ '^\.')
            ORDER BY entry.name
        ) ordered;
        RETURN result;
    END IF;

    SELECT convert_to(
        COALESCE(string_agg(listed.name, E'\n' ORDER BY listed.name COLLATE "C") || E'\n', ''),
        'UTF8'
    )
    INTO result
    FROM (
        SELECT entry.name::text AS name
        FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND entry.parent_path = location.relative_path
        UNION ALL
        SELECT zone.name::text
        FROM pgos_private.zones zone
        WHERE zone.volume_id = target_volume AND zone.parent_zone_id = location.zone_id
          AND zone.parent_path = location.relative_path
    ) listed
    WHERE include_hidden OR listed.name !~ '^\.';
    RETURN result;
END
$$;


--
-- Name: mkdir(text, boolean, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.mkdir(target_path text, parents boolean DEFAULT false, target_mode integer DEFAULT 493) RETURNS void
    LANGUAGE sql
    AS $$
    SELECT pgos.mkdir(pgos.current_volume(), target_path, parents, target_mode)
$$;


--
-- Name: mkdir(uuid, text, boolean, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.mkdir(target_volume uuid, target_path text, parents boolean DEFAULT false, target_mode integer DEFAULT 493) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    current_path text := '';
    part text;
    parent_location record;
    entry_relative_path text;
BEGIN
    IF clean_path = '/' THEN RETURN; END IF;
    IF parents THEN
        FOREACH part IN ARRAY string_to_array(trim(leading '/' FROM clean_path), '/') LOOP
            current_path := current_path || '/' || part;
            IF pgos_private.kind_of(target_volume, current_path) IS NULL THEN
                PERFORM pgos.mkdir(target_volume, current_path, false, target_mode);
            ELSIF pgos_private.kind_of(target_volume, current_path) <> 2 THEN
                RAISE EXCEPTION 'not a directory: %', current_path USING ERRCODE = '42809';
            END IF;
        END LOOP;
        RETURN;
    END IF;

    IF pgos_private.kind_of(target_volume, clean_path) IS NOT NULL THEN
        RAISE EXCEPTION 'path exists: %', clean_path USING ERRCODE = '23505';
    END IF;
    IF pgos_private.kind_of(target_volume, pgos_private.parent_of(clean_path)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'parent directory does not exist: %', clean_path USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO STRICT parent_location
    FROM pgos_private.locate_zone(target_volume, pgos_private.parent_of(clean_path));
    entry_relative_path := CASE
        WHEN parent_location.relative_path = '' THEN pgos_private.name_of(clean_path)
        ELSE parent_location.relative_path || '/' || pgos_private.name_of(clean_path)
    END;
    INSERT INTO pgos_private.zone_entries
        (volume_id, zone_id, relative_path, parent_path, name, kind, mode)
    VALUES (target_volume, parent_location.zone_id, entry_relative_path,
            parent_location.relative_path, pgos_private.name_of(clean_path), 2, target_mode);
END
$$;


--
-- Name: mkdir_entry(uuid, text, boolean, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.mkdir_entry(target_volume uuid, target_path text, parents boolean DEFAULT false, target_mode integer DEFAULT 493) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM pgos.mkdir(target_volume, target_path, parents, target_mode);
    RETURN QUERY SELECT * FROM pgos.stat(target_volume, target_path);
END
$$;


--
-- Name: mkdir_many(text[], boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.mkdir_many(target_paths text[], parents boolean DEFAULT false) RETURNS void
    LANGUAGE sql
    AS $$
    SELECT pgos.mkdir_many(pgos.current_volume(), target_paths, parents)
$$;


--
-- Name: mkdir_many(uuid, text[], boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.mkdir_many(target_volume uuid, target_paths text[], parents boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    target_path text;
BEGIN
    IF parents THEN
        FOREACH target_path IN ARRAY target_paths LOOP
            PERFORM pgos.mkdir(target_volume, target_path, true);
        END LOOP;
        RETURN;
    END IF;

    IF EXISTS (
        WITH requested_parents AS MATERIALIZED (
            SELECT DISTINCT pgos_private.parent_of(
                pgos_private.assert_path(value)
            ) AS parent_path
            FROM unnest(target_paths) AS input(value)
        )
        SELECT 1
        FROM requested_parents
        WHERE pgos_private.kind_of(target_volume, requested_parents.parent_path) IS DISTINCT FROM 2
    ) THEN
        RAISE EXCEPTION 'a parent directory does not exist' USING ERRCODE = 'P0002';
    END IF;

    WITH clean_paths AS MATERIALIZED (
        SELECT pgos_private.assert_path(value) AS path
        FROM unnest(target_paths) AS input(value)
    ), requested AS MATERIALIZED (
        SELECT clean_paths.path,
               pgos_private.parent_of(clean_paths.path) AS parent_path,
               pgos_private.name_of(clean_paths.path) AS name
        FROM clean_paths
    ),
    parents AS MATERIALIZED (
        SELECT DISTINCT requested.parent_path FROM requested
    ),
    locations AS MATERIALIZED (
        SELECT parents.parent_path, location.*
        FROM parents
        CROSS JOIN LATERAL pgos_private.locate_zone(target_volume, parents.parent_path) location
    ),
    resolved AS MATERIALIZED (
        SELECT requested.path, requested.name, locations.zone_id,
               locations.relative_path AS parent_relative,
               CASE WHEN locations.relative_path = '' THEN requested.name
                    ELSE locations.relative_path || '/' || requested.name END AS relative_path
        FROM requested JOIN locations USING (parent_path)
    )
    INSERT INTO pgos_private.zone_entries
        (volume_id, zone_id, relative_path, parent_path, name, kind, mode)
    SELECT target_volume, resolved.zone_id, resolved.relative_path,
           resolved.parent_relative, resolved.name, 2, 493
    FROM resolved;
END
$$;


--
-- Name: move(text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.move(source_path text, destination_path text) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.move(pgos.current_volume(), source_path, destination_path)
$$;


--
-- Name: move(uuid, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.move(target_volume uuid, source_path text, destination_path text) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_source text := pgos_private.assert_path(source_path);
    clean_destination text := pgos_private.assert_path(destination_path);
    source_location record;
    destination_parent_location record;
    destination_location record;
    destination_kind smallint;
    destination_relative text;
    moved_count bigint;
BEGIN
    IF clean_source = '/' OR clean_destination = clean_source
       OR clean_destination LIKE clean_source || '/%' THEN
        RAISE EXCEPTION 'cannot move this path' USING ERRCODE = '22023';
    END IF;
    IF pgos_private.kind_of(target_volume, clean_source) IS NULL THEN
        RAISE EXCEPTION 'source does not exist: %', clean_source USING ERRCODE = 'P0002';
    END IF;
    IF pgos_private.kind_of(target_volume, pgos_private.parent_of(clean_destination)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'destination parent does not exist: %', clean_destination
            USING ERRCODE = 'P0002';
    END IF;
    destination_kind := pgos_private.kind_of(target_volume, clean_destination);
    IF destination_kind = 2 THEN
        RAISE EXCEPTION 'destination is a directory: %', clean_destination USING ERRCODE = '23505';
    ELSIF destination_kind IS NOT NULL THEN
        SELECT * INTO STRICT destination_location
        FROM pgos_private.locate_zone(target_volume, clean_destination);
        DELETE FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = destination_location.zone_id
          AND entry.relative_path = destination_location.relative_path;
    END IF;

    SELECT * INTO STRICT source_location
    FROM pgos_private.locate_zone(target_volume, clean_source);
    SELECT * INTO STRICT destination_parent_location
    FROM pgos_private.locate_zone(target_volume, pgos_private.parent_of(clean_destination));

    IF source_location.relative_path = '' THEN
        SELECT
            (SELECT count(*)
             FROM pgos_private.zones z
             WHERE z.volume_id = target_volume
               AND (z.path = clean_source OR z.path LIKE clean_source || '/%'))
            +
            (SELECT count(*)
             FROM pgos_private.zone_entries entry
             JOIN pgos_private.zones z ON z.id = entry.zone_id
             WHERE entry.volume_id = target_volume AND z.volume_id = target_volume
               AND (z.path = clean_source OR z.path LIKE clean_source || '/%'))
        INTO moved_count;

        UPDATE pgos_private.zones z
        SET path = clean_destination || substr(z.path, length(clean_source) + 1),
            parent_zone_id = CASE WHEN z.id = source_location.zone_id
                                  THEN destination_parent_location.zone_id ELSE z.parent_zone_id END,
            parent_path = CASE WHEN z.id = source_location.zone_id
                               THEN destination_parent_location.relative_path ELSE z.parent_path END,
            name = CASE WHEN z.id = source_location.zone_id
                        THEN pgos_private.name_of(clean_destination) ELSE z.name END,
            ctime = CASE WHEN z.id = source_location.zone_id THEN clock_timestamp() ELSE z.ctime END,
            generation = CASE WHEN z.id = source_location.zone_id THEN z.generation + 1 ELSE z.generation END
        WHERE z.volume_id = target_volume
          AND (z.path = clean_source OR z.path LIKE clean_source || '/%');
        RETURN moved_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pgos_private.zones z
        WHERE z.volume_id = target_volume AND z.path LIKE clean_source || '/%'
    ) THEN
        RAISE EXCEPTION 'moving an entry with nested zones is not implemented'
            USING ERRCODE = '0A000';
    END IF;
    destination_relative := CASE
        WHEN destination_parent_location.relative_path = '' THEN pgos_private.name_of(clean_destination)
        ELSE destination_parent_location.relative_path || '/' || pgos_private.name_of(clean_destination)
    END;
    UPDATE pgos_private.zone_entries entry
    SET zone_id = destination_parent_location.zone_id,
        relative_path = destination_relative
            || substr(entry.relative_path, length(source_location.relative_path) + 1),
        parent_path = pgos_private.relative_parent(
            destination_relative || substr(entry.relative_path, length(source_location.relative_path) + 1)
        ),
        name = CASE WHEN entry.relative_path = source_location.relative_path
                    THEN pgos_private.name_of(clean_destination) ELSE entry.name END,
        ctime = clock_timestamp(), generation = entry.generation + 1
    WHERE entry.volume_id = target_volume AND entry.zone_id = source_location.zone_id
      AND (entry.relative_path = source_location.relative_path
           OR entry.relative_path LIKE source_location.relative_path || '/%');
    GET DIAGNOSTICS moved_count = ROW_COUNT;
    RETURN moved_count;
END
$$;


--
-- Name: move_command(uuid, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.move_command(target_volume uuid, source_path text, destination_path text) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_source text := pgos_private.assert_path(source_path);
    clean_destination text := pgos_private.assert_path(destination_path);
    source_location record;
    destination_parent_location record;
    destination_location record;
    destination_kind smallint;
    moved_count bigint;
BEGIN
    SELECT * INTO STRICT source_location
    FROM pgos_private.locate_zone(target_volume, clean_source);
    IF source_location.relative_path <> '' THEN
        RETURN pgos.move(target_volume, clean_source, clean_destination);
    END IF;
    IF clean_source = '/' OR clean_destination = clean_source
       OR clean_destination LIKE clean_source || '/%' THEN
        RAISE EXCEPTION 'cannot move this path' USING ERRCODE = '22023';
    END IF;
    IF pgos_private.kind_of(
        target_volume, pgos_private.parent_of(clean_destination)
    ) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'destination parent does not exist: %', clean_destination
            USING ERRCODE = 'P0002';
    END IF;
    destination_kind := pgos_private.kind_of(target_volume, clean_destination);
    IF destination_kind = 2 THEN
        RAISE EXCEPTION 'destination is a directory: %', clean_destination
            USING ERRCODE = '23505';
    ELSIF destination_kind IS NOT NULL THEN
        SELECT * INTO STRICT destination_location
        FROM pgos_private.locate_zone(target_volume, clean_destination);
        DELETE FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume
          AND entry.zone_id = destination_location.zone_id
          AND entry.relative_path = destination_location.relative_path;
    END IF;
    SELECT * INTO STRICT destination_parent_location
    FROM pgos_private.locate_zone(
        target_volume, pgos_private.parent_of(clean_destination)
    );

    SELECT count(*) + COALESCE(sum(zone.entry_count), 0)
    INTO moved_count
    FROM pgos_private.zones zone
    WHERE zone.volume_id = target_volume
      AND (zone.path = clean_source OR zone.path LIKE clean_source || '/%');

    UPDATE pgos_private.zones zone
    SET path = clean_destination || substr(zone.path, length(clean_source) + 1),
        parent_zone_id = CASE WHEN zone.id = source_location.zone_id
                              THEN destination_parent_location.zone_id
                              ELSE zone.parent_zone_id END,
        parent_path = CASE WHEN zone.id = source_location.zone_id
                           THEN destination_parent_location.relative_path
                           ELSE zone.parent_path END,
        name = CASE WHEN zone.id = source_location.zone_id
                    THEN pgos_private.name_of(clean_destination) ELSE zone.name END,
        ctime = CASE WHEN zone.id = source_location.zone_id
                     THEN clock_timestamp() ELSE zone.ctime END,
        generation = CASE WHEN zone.id = source_location.zone_id
                          THEN zone.generation + 1 ELSE zone.generation END
    WHERE zone.volume_id = target_volume
      AND (zone.path = clean_source OR zone.path LIKE clean_source || '/%');
    RETURN moved_count;
END
$$;


--
-- Name: prepare_import(text, uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.prepare_import(destination_path text, batch uuid) RETURNS void
    LANGUAGE sql
    AS $$
    SELECT pgos.prepare_import(pgos.current_volume(), destination_path, batch)
$$;


--
-- Name: prepare_import(uuid, text, uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.prepare_import(target_volume uuid, destination_path text, batch uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    clean_destination text := pgos_private.assert_path(destination_path);
BEGIN
    IF clean_destination = '/' THEN
        RAISE EXCEPTION 'cannot import over the volume root' USING ERRCODE = '22023';
    END IF;
    IF pgos_private.kind_of(target_volume, pgos_private.parent_of(clean_destination)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'destination parent does not exist: %', clean_destination
            USING ERRCODE = 'P0002';
    END IF;
    IF pgos_private.kind_of(target_volume, clean_destination) IS NOT NULL THEN
        RAISE EXCEPTION 'destination exists: %', clean_destination USING ERRCODE = '23505';
    END IF;

    CREATE TEMPORARY TABLE IF NOT EXISTS pgos_import_staging (
        batch_id uuid NOT NULL,
        ordinal bigint NOT NULL,
        relative_path text NOT NULL,
        kind smallint NOT NULL CHECK (kind IN (1, 2, 3)),
        content bytea NOT NULL,
        mode integer NOT NULL,
        uid integer NOT NULL,
        gid integer NOT NULL,
        mtime_seconds bigint NOT NULL,
        mtime_nanoseconds integer NOT NULL CHECK (mtime_nanoseconds BETWEEN 0 AND 999999999),
        link_target text NOT NULL,
        PRIMARY KEY (batch_id, ordinal),
        UNIQUE (batch_id, relative_path)
    ) ON COMMIT DROP;

    CREATE TEMPORARY TABLE IF NOT EXISTS pgos_import_context (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        batch_id uuid NOT NULL,
        volume_id uuid NOT NULL,
        destination text NOT NULL
    ) ON COMMIT DROP;

    INSERT INTO pg_temp.pgos_import_context
        (singleton, batch_id, volume_id, destination)
    VALUES (true, batch, target_volume, clean_destination);
END
$$;


--
-- Name: publish_content(uuid, text, uuid, bigint); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.publish_content(target_volume uuid, target_path text, object uuid, bytes bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    result bigint;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pgos_private.content_objects
        WHERE id = object AND volume_id = target_volume
    ) THEN
        RAISE EXCEPTION 'content object does not belong to volume' USING ERRCODE = '22023';
    END IF;
    UPDATE pgos_private.content_objects SET byte_size = bytes WHERE id = object;
    result := pgos.write_file_inline(target_volume, target_path, ''::bytea, 420);
    UPDATE pgos_private.zone_entries
    SET content_object = object, size = bytes
    WHERE volume_id = target_volume AND id = result;
    RETURN result;
END
$$;


--
-- Name: read_file(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.read_file(target_path text) RETURNS bytea
    LANGUAGE sql STABLE
    AS $$
    SELECT pgos.read_file(pgos.current_volume(), target_path)
$$;


--
-- Name: read_file(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.read_file(target_volume uuid, target_path text) RETURNS bytea
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    location record;
    result bytea;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);
    IF location.relative_path = '' THEN
        RAISE EXCEPTION 'not a regular file: %', target_path USING ERRCODE = '42809';
    END IF;
    SELECT pgos_private.entry_bytes(e.text_content, e.binary_content, e.content_object)
    INTO result
    FROM pgos_private.zone_entries e
    WHERE e.volume_id = target_volume AND e.zone_id = location.zone_id
      AND e.relative_path = location.relative_path AND e.kind = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'path does not exist or is not a regular file: %', target_path
            USING ERRCODE = 'P0002';
    END IF;
    RETURN result;
END
$$;


--
-- Name: read_files(text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.read_files(target_paths text[]) RETURNS TABLE(ordinality bigint, path text, data bytea)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.read_files(pgos.current_volume(), target_paths)
$$;


--
-- Name: read_files(uuid, text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.read_files(target_volume uuid, target_paths text[]) RETURNS TABLE(ordinality bigint, path text, data bytea)
    LANGUAGE sql STABLE
    AS $$
    WITH clean_paths AS MATERIALIZED (
        SELECT pgos_private.assert_path(value) AS path, ordinality
        FROM unnest(target_paths) WITH ORDINALITY AS input(value, ordinality)
    ), requested AS MATERIALIZED (
        SELECT clean_paths.path, clean_paths.ordinality,
               pgos_private.parent_of(clean_paths.path) AS parent_path,
               pgos_private.name_of(clean_paths.path) AS name
        FROM clean_paths
    ),
    parents AS MATERIALIZED (
        SELECT DISTINCT requested.parent_path FROM requested
    ),
    locations AS MATERIALIZED (
        SELECT parents.parent_path, location.*
        FROM parents
        CROSS JOIN LATERAL pgos_private.locate_zone(target_volume, parents.parent_path) location
    )
    SELECT requested.ordinality, requested.path,
           pgos_private.entry_bytes(entry.text_content, entry.binary_content, entry.content_object)
    FROM requested
    JOIN locations ON locations.parent_path = requested.parent_path
    LEFT JOIN pgos_private.zone_entries entry
      ON entry.volume_id = target_volume
     AND entry.zone_id = locations.zone_id
     AND entry.relative_path = CASE
         WHEN locations.relative_path = '' THEN requested.name
         ELSE locations.relative_path || '/' || requested.name
     END
     AND entry.kind = 1
    ORDER BY requested.ordinality
$$;


--
-- Name: read_range(uuid, text, bigint, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.read_range(target_volume uuid, target_path text, start_byte bigint, byte_count integer) RETURNS bytea
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE entry record; result bytea; end_byte bigint;
BEGIN
    IF start_byte < 0 OR byte_count < 0 OR byte_count > 16777216 THEN
        RAISE EXCEPTION 'invalid read range' USING ERRCODE = '22023';
    END IF;
    SELECT e.* INTO entry
    FROM pgos_private.locate_zone(target_volume, target_path) location
    JOIN pgos_private.zone_entries e ON e.volume_id = target_volume
        AND e.zone_id = location.zone_id AND e.relative_path = location.relative_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'file does not exist: %', target_path USING ERRCODE = 'P0002';
    END IF;
    IF entry.kind <> 1 THEN
        RAISE EXCEPTION 'not a regular file: %', target_path USING ERRCODE = '42809';
    END IF;
    IF start_byte >= entry.size OR byte_count = 0 THEN RETURN ''::bytea; END IF;
    end_byte := start_byte + least(byte_count::bigint, entry.size - start_byte);
    IF entry.content_object IS NULL THEN
        RETURN substring(pgos_private.entry_bytes(entry.text_content, entry.binary_content)
                         FROM start_byte::integer + 1 FOR byte_count);
    END IF;
    SELECT string_agg(substring(convert_to(b.body, 'UTF8')
        FROM greatest(start_byte - b.byte_offset, 0)::integer + 1
        FOR (least(end_byte - b.byte_offset, octet_length(b.body))
             - greatest(start_byte - b.byte_offset, 0))::integer), ''::bytea ORDER BY b.ordinal)
    INTO result FROM pgos_private.all_content_blocks b
    WHERE b.object_id = entry.content_object
        AND b.byte_offset >= (SELECT max(previous.byte_offset) FROM pgos_private.all_content_blocks previous
                              WHERE previous.object_id = entry.content_object AND previous.byte_offset <= start_byte)
        AND b.byte_offset < end_byte;
    RETURN coalesce(result, ''::bytea);
END
$$;


--
-- Name: remove(text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.remove(target_path text, recursive boolean DEFAULT false) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.remove(pgos.current_volume(), target_path, recursive)
$$;


--
-- Name: remove(uuid, text, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.remove(target_volume uuid, target_path text, recursive boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    target text := pgos_private.assert_path(target_path);
    location record;
    target_kind smallint;
    removed_entries bigint := 0;
    removed_zones bigint := 0;
    removed_here bigint := 0;
BEGIN
    IF target = '/' THEN
        RAISE EXCEPTION 'cannot remove the volume root' USING ERRCODE = '22023';
    END IF;
    target_kind := pgos_private.kind_of(target_volume, target);
    IF target_kind IS NULL THEN
        RAISE EXCEPTION 'path does not exist: %', target USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target);

    IF target_kind = 2 AND NOT recursive AND EXISTS (
        SELECT 1 FROM pgos.list(target_volume, target) LIMIT 1
    ) THEN
        RAISE EXCEPTION 'directory not empty: %', target USING ERRCODE = '2BP01';
    END IF;

    IF location.relative_path = '' THEN
        WITH selected_zones AS (
            SELECT id FROM pgos_private.zones
            WHERE volume_id = target_volume
              AND (path = target OR path LIKE target || '/%')
        ), deleted AS (
            DELETE FROM pgos_private.zone_entries entry
            USING selected_zones selected
            WHERE entry.volume_id = target_volume AND entry.zone_id = selected.id
            RETURNING 1
        )
        SELECT count(*) INTO removed_entries FROM deleted;

        WITH deleted AS (
            DELETE FROM pgos_private.zones
            WHERE volume_id = target_volume
              AND (path = target OR path LIKE target || '/%')
            RETURNING 1
        )
        SELECT count(*) INTO removed_zones FROM deleted;
        PERFORM pgos_private.reclaim_content_segments(target_volume);
        RETURN removed_entries + removed_zones;
    END IF;

    IF recursive THEN
        WITH selected_zones AS (
            SELECT id FROM pgos_private.zones
            WHERE volume_id = target_volume AND path LIKE target || '/%'
        ), deleted AS (
            DELETE FROM pgos_private.zone_entries entry
            USING selected_zones selected
            WHERE entry.volume_id = target_volume AND entry.zone_id = selected.id
            RETURNING 1
        )
        SELECT count(*) INTO removed_entries FROM deleted;

        WITH deleted AS (
            DELETE FROM pgos_private.zones
            WHERE volume_id = target_volume AND path LIKE target || '/%'
            RETURNING 1
        )
        SELECT count(*) INTO removed_zones FROM deleted;
    END IF;

    WITH deleted AS (
        DELETE FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND (entry.relative_path = location.relative_path
               OR (recursive AND entry.relative_path LIKE location.relative_path || '/%'))
        RETURNING 1
    )
    SELECT count(*) INTO removed_here FROM deleted;
    removed_entries := removed_entries + removed_here;
    PERFORM pgos_private.reclaim_content_segments(target_volume);
    RETURN removed_entries + removed_zones;
END
$$;


--
-- Name: remove_many(text[], boolean, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.remove_many(target_paths text[], recursive boolean DEFAULT false, force_missing boolean DEFAULT false) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.remove_many(
        pgos.current_volume(), target_paths, recursive, force_missing
    )
$$;


--
-- Name: remove_many(uuid, text[], boolean, boolean); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.remove_many(target_volume uuid, target_paths text[], recursive boolean DEFAULT false, force_missing boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    target_path text;
    result bigint := 0;
    removed bigint;
BEGIN
    IF cardinality(target_paths) = 1 THEN
        IF force_missing AND pgos_private.kind_of(target_volume, target_paths[1]) IS NULL THEN
            RETURN 0;
        END IF;
        RETURN pgos.remove(target_volume, target_paths[1], recursive);
    END IF;

    -- Exact entries with shared parents are deleted in one statement. This is
    -- the common bulk cleanup path used by `rm` and `mkdir` workloads.
    IF NOT EXISTS (
        SELECT 1 FROM unnest(target_paths) input(path)
        JOIN pgos_private.zones z
          ON z.volume_id = target_volume
         AND z.path = pgos_private.assert_path(input.path)
    ) THEN
        WITH clean_paths AS MATERIALIZED (
            SELECT pgos_private.assert_path(value) AS path
            FROM unnest(target_paths) input(value)
        ), requested AS MATERIALIZED (
            SELECT clean_paths.path,
                   pgos_private.parent_of(clean_paths.path) AS parent_path,
                   pgos_private.name_of(clean_paths.path) AS name
            FROM clean_paths
        ), parents AS MATERIALIZED (
            SELECT DISTINCT parent_path FROM requested
        ), locations AS MATERIALIZED (
            SELECT parents.parent_path, location.*
            FROM parents
            CROSS JOIN LATERAL pgos_private.locate_zone(target_volume, parents.parent_path) location
        ), resolved AS MATERIALIZED (
            SELECT locations.zone_id,
                   CASE WHEN locations.relative_path = '' THEN requested.name
                        ELSE locations.relative_path || '/' || requested.name END AS relative_path
            FROM requested JOIN locations USING (parent_path)
        ), selected AS (
            SELECT entry.volume_id, entry.zone_id, entry.id
            FROM resolved
            JOIN pgos_private.zone_entries entry
              ON entry.volume_id = target_volume AND entry.zone_id = resolved.zone_id
             AND entry.relative_path = resolved.relative_path
            WHERE recursive OR entry.kind <> 2 OR NOT EXISTS (
                SELECT 1 FROM pgos_private.zone_entries child
                WHERE child.volume_id = target_volume AND child.zone_id = entry.zone_id
                  AND child.parent_path = entry.relative_path
            )
        ), deleted AS (
            DELETE FROM pgos_private.zone_entries entry
            USING selected
            WHERE entry.volume_id = selected.volume_id
              AND entry.zone_id = selected.zone_id AND entry.id = selected.id
            RETURNING 1
        )
        SELECT count(*) INTO result FROM deleted;

        IF NOT force_missing AND result <> cardinality(target_paths) THEN
            RAISE EXCEPTION 'a path does not exist or a directory is not empty'
                USING ERRCODE = 'P0002';
        END IF;
        PERFORM pgos_private.reclaim_content_segments(target_volume);
        RETURN result;
    END IF;

    FOREACH target_path IN ARRAY target_paths LOOP
        IF force_missing AND pgos_private.kind_of(target_volume, target_path) IS NULL THEN
            CONTINUE;
        END IF;
        removed := pgos.remove(target_volume, target_path, recursive);
        result := result + removed;
    END LOOP;
    RETURN result;
END
$$;


--
-- Name: remove_volume(uuid); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.remove_volume(target_volume uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    volume_table text := pgos_private.volume_relation(target_volume);
BEGIN
    DELETE FROM pgos_private.zone_entries WHERE volume_id = target_volume;
    PERFORM pgos_private.reclaim_content_segments(target_volume);
    IF to_regclass('pgos_private.' || volume_table) IS NOT NULL THEN
        EXECUTE format('DROP TABLE pgos_private.%I', volume_table);
    END IF;
    DELETE FROM pgos_private.volumes WHERE id = target_volume;
END
$$;


--
-- Name: search_candidate_blocks(uuid, text, text[], text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_candidate_blocks(target_volume uuid, target_path text, needles text[], file_suffixes text[]) RETURNS TABLE(path text, first_line bigint, body text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);

    IF cardinality(needles) = 1 THEN
        RETURN QUERY
        WITH eligible_objects AS MATERIALIZED (
            SELECT pgos_private.absolute_path(
                       location.zone_path, entry.relative_path
                   ) AS path,
                   entry.content_object AS object_id
            FROM pgos_private.zone_entries entry
            WHERE entry.volume_id = target_volume
              AND entry.zone_id = location.zone_id
              AND entry.kind = 1
              AND (cardinality(file_suffixes) = 0 OR EXISTS (
                  SELECT 1 FROM unnest(file_suffixes) suffix
                  WHERE right(entry.name, length(suffix)) = suffix
              ))
              AND (location.relative_path = ''
                   OR entry.relative_path = location.relative_path
                   OR entry.relative_path LIKE location.relative_path || '/%')

            UNION ALL

            SELECT pgos_private.absolute_path(zone.path, entry.relative_path),
                   entry.content_object
            FROM pgos_private.zones zone
            JOIN pgos_private.zone_entries entry
              ON entry.volume_id = target_volume AND entry.zone_id = zone.id
            WHERE zone.volume_id = target_volume
              AND zone.id <> location.zone_id
              AND (clean_path = '/' OR zone.path = clean_path
                   OR zone.path LIKE clean_path || '/%')
              AND entry.kind = 1
              AND (cardinality(file_suffixes) = 0 OR EXISTS (
                  SELECT 1 FROM unnest(file_suffixes) suffix
                  WHERE right(entry.name, length(suffix)) = suffix
              ))
        ), matching_blocks AS MATERIALIZED (
            SELECT eligible.path, block.ordinal, block.first_line, block.body
            FROM eligible_objects eligible
            JOIN pgos_private.all_content_blocks block
              ON block.object_id = eligible.object_id
             AND block.volume_id = target_volume
            WHERE block.body LIKE needles[1]
        ), candidates AS (
            SELECT block.path, block.ordinal,
                   block.first_line + line.number - 1 AS first_line,
                   line.body || E'\n' AS body,
                   line.number
            FROM matching_blocks block
            CROSS JOIN LATERAL string_to_table(block.body, E'\n')
                WITH ORDINALITY AS line(body, number)
            WHERE line.body LIKE needles[1]
        )
        SELECT candidates.path, candidates.first_line, candidates.body
        FROM candidates
        ORDER BY candidates.path COLLATE "C", candidates.ordinal,
                 candidates.number;
        RETURN;
    END IF;

    RETURN QUERY
    WITH matching_blocks AS MATERIALIZED (
        SELECT block.object_id, block.ordinal, block.first_line, block.body
        FROM pgos_private.matching_content_blocks(target_volume, needles) block
    ), candidates AS (
        SELECT pgos_private.absolute_path(
                   location.zone_path, entry.relative_path
               ) AS path,
               block.ordinal, block.first_line, block.body
        FROM pgos_private.zone_entries entry
        JOIN matching_blocks block ON block.object_id = entry.content_object
        WHERE entry.volume_id = target_volume
          AND entry.zone_id = location.zone_id
          AND entry.kind = 1
          AND (cardinality(file_suffixes) = 0 OR EXISTS (
              SELECT 1 FROM unnest(file_suffixes) suffix
              WHERE right(entry.name, length(suffix)) = suffix
          ))
          AND (location.relative_path = ''
               OR entry.relative_path = location.relative_path
               OR entry.relative_path LIKE location.relative_path || '/%')

        UNION ALL

        SELECT pgos_private.absolute_path(zone.path, entry.relative_path),
               block.ordinal, block.first_line, block.body
        FROM pgos_private.zones zone
        JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume AND entry.zone_id = zone.id
        JOIN matching_blocks block ON block.object_id = entry.content_object
        WHERE zone.volume_id = target_volume
          AND zone.id <> location.zone_id
          AND (clean_path = '/' OR zone.path = clean_path
               OR zone.path LIKE clean_path || '/%')
          AND entry.kind = 1
          AND (cardinality(file_suffixes) = 0 OR EXISTS (
              SELECT 1 FROM unnest(file_suffixes) suffix
              WHERE right(entry.name, length(suffix)) = suffix
          ))
    )
    SELECT candidates.path, candidates.first_line, candidates.body
    FROM candidates
    ORDER BY candidates.path COLLATE "C", candidates.ordinal;
END
$$;


--
-- Name: search_candidate_files(uuid, text, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_candidate_files(target_volume uuid, target_path text, needle text, identifier_regex text) RETURNS TABLE(path text, text_content text)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.search_literal_files(target_volume, target_path, needle)
$$;


--
-- Name: search_file_blocks(uuid, text, text[]); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_file_blocks(target_volume uuid, target_path text, needles text[]) RETURNS TABLE(first_line bigint, body text)
    LANGUAGE sql STABLE
    AS $$
    SELECT block.first_line, block.body
    FROM pgos_private.file_content(target_volume, target_path) file
    CROSS JOIN LATERAL (
        (SELECT b.first_line, b.body FROM pgos_private.all_content_blocks b
         WHERE b.object_id = file.object_id AND (needles IS NULL OR b.body LIKE ANY(needles))
         ORDER BY b.ordinal)
        UNION ALL
        SELECT 1::bigint, file.inline_text WHERE file.object_id IS NULL
            AND (needles IS NULL OR file.inline_text LIKE ANY(needles))
    ) block
$$;


--
-- Name: search_literal(text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_literal(target_path text, needle text) RETURNS TABLE(path text, size bigint, generation bigint)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.search_literal(pgos.current_volume(), target_path, needle)
$$;


--
-- Name: search_literal(uuid, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_literal(target_volume uuid, target_path text, needle text) RETURNS TABLE(path text, size bigint, generation bigint)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);
    RETURN QUERY
    WITH selected_zones AS (
        SELECT z.id, z.path,
               CASE WHEN z.id = location.zone_id THEN location.relative_path ELSE '' END AS relative_root
        FROM pgos_private.zones z
        WHERE z.volume_id = target_volume
          AND (z.id = location.zone_id OR clean_path = '/'
               OR z.path = clean_path OR z.path LIKE clean_path || '/%')
    )
    SELECT pgos_private.absolute_path(selected.path, entry.relative_path),
           entry.size, entry.generation
    FROM selected_zones selected
    JOIN pgos_private.zone_entries entry
      ON entry.volume_id = target_volume AND entry.zone_id = selected.id
    WHERE entry.kind = 1
      AND (entry.text_content LIKE '%' || replace(replace(replace(
            needle, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\'
           OR EXISTS (SELECT 1 FROM pgos_private.all_content_blocks b
                      WHERE b.object_id = entry.content_object
                        AND b.body LIKE '%' || replace(replace(replace(
                            needle, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\'))
      AND (selected.relative_root = ''
           OR entry.relative_path = selected.relative_root
           OR entry.relative_path LIKE selected.relative_root || '/%')
    ORDER BY selected.path COLLATE "C", entry.relative_path;
END
$$;


--
-- Name: search_literal_files(text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_literal_files(target_path text, needle text) RETURNS TABLE(path text, text_content text)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.search_literal_files(
        pgos.current_volume(), target_path, needle
    )
$$;


--
-- Name: search_literal_files(uuid, text, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.search_literal_files(target_volume uuid, target_path text, needle text) RETURNS TABLE(path text, text_content text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    location record;
    escaped_pattern text := '%' || replace(replace(replace(
        needle, '\', '\\'), '%', '\%'), '_', '\_') || '%';
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, clean_path);
    -- The old whole-file API cannot represent a file above PostgreSQL's value
    -- limit. Fail explicitly instead of searching its empty inline placeholder.
    IF EXISTS (
        SELECT 1 FROM pgos_private.zone_entries e
        JOIN pgos_private.zones z ON z.volume_id = e.volume_id AND z.id = e.zone_id
        WHERE e.volume_id = target_volume AND e.content_object IS NOT NULL
          AND (clean_path = '/' OR pgos_private.absolute_path(z.path, e.relative_path) = clean_path
               OR starts_with(pgos_private.absolute_path(z.path, e.relative_path), clean_path || '/'))
    ) THEN
        RAISE EXCEPTION 'block-backed files require the streaming search API' USING ERRCODE = '0A000';
    END IF;
    RETURN QUERY
    WITH matches AS MATERIALIZED (
        SELECT pgos_private.absolute_path(location.zone_path, entry.relative_path) AS path,
               entry.text_content
        FROM pgos_private.zone_entries entry
        WHERE entry.volume_id = target_volume
          AND entry.zone_id = location.zone_id
          AND entry.kind = 1
          AND entry.text_content IS NOT NULL
          AND entry.text_content LIKE escaped_pattern
          AND (location.relative_path = ''
               OR entry.relative_path = location.relative_path
               OR entry.relative_path LIKE location.relative_path || '/%')

        UNION ALL

        SELECT pgos_private.absolute_path(zone.path, entry.relative_path),
               entry.text_content
        FROM pgos_private.zones zone
        JOIN pgos_private.zone_entries entry
          ON entry.volume_id = target_volume AND entry.zone_id = zone.id
        WHERE zone.volume_id = target_volume
          AND zone.id <> location.zone_id
          AND (clean_path = '/' OR zone.path = clean_path
               OR zone.path LIKE clean_path || '/%')
          AND entry.kind = 1
          AND entry.text_content IS NOT NULL
          AND entry.text_content LIKE escaped_pattern
    )
    SELECT matches.path, matches.text_content
    FROM matches
    ORDER BY matches.path COLLATE "C";
END
$$;


--
-- Name: set_times(uuid, text, bigint, integer, bigint, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.set_times(target_volume uuid, target_path text, atime_seconds bigint, atime_nanoseconds integer, mtime_seconds bigint, mtime_nanoseconds integer) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    location record;
    new_atime timestamptz := to_timestamp(
        atime_seconds::double precision + atime_nanoseconds::double precision / 1000000000
    );
    new_mtime timestamptz := to_timestamp(
        mtime_seconds::double precision + mtime_nanoseconds::double precision / 1000000000
    );
BEGIN
    IF atime_nanoseconds NOT BETWEEN 0 AND 999999999
       OR mtime_nanoseconds NOT BETWEEN 0 AND 999999999 THEN
        RAISE EXCEPTION 'timestamp nanoseconds are outside the valid range'
            USING ERRCODE = '22003';
    END IF;

    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);

    IF location.relative_path = '' THEN
        UPDATE pgos_private.zones AS zone
        SET atime = new_atime, mtime = new_mtime,
            ctime = clock_timestamp(), generation = zone.generation + 1
        WHERE zone.volume_id = target_volume AND zone.id = location.zone_id;
    ELSE
        UPDATE pgos_private.zone_entries AS entry
        SET atime = new_atime, mtime = new_mtime,
            ctime = clock_timestamp(), generation = entry.generation + 1
        WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
          AND entry.relative_path = location.relative_path;
    END IF;

    RETURN QUERY SELECT * FROM pgos.stat(target_volume, target_path);
END
$$;


--
-- Name: stat(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.stat(target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.stat(pgos.current_volume(), target_path)
$$;


--
-- Name: stat(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.stat(target_volume uuid, target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    location record;
BEGIN
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);
    IF location.relative_path = '' THEN
        RETURN QUERY
        SELECT z.id, z.path::text, z.name::text, 2::smallint, z.mode,
               z.uid, z.gid, 0::bigint, z.atime, z.mtime, z.ctime,
               z.generation, NULL::text
        FROM pgos_private.zones z WHERE z.id = location.zone_id;
    ELSE
        RETURN QUERY
        SELECT e.id, pgos_private.absolute_path(location.zone_path, e.relative_path),
               e.name::text, e.kind, e.mode, e.uid, e.gid, e.size,
               e.atime, e.mtime, e.ctime, e.generation, e.link_target
        FROM pgos_private.zone_entries e
        WHERE e.volume_id = target_volume AND e.zone_id = location.zone_id
          AND e.relative_path = location.relative_path;
    END IF;
END
$$;


--
-- Name: use_volume(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.use_volume(volume_name text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    selected uuid;
BEGIN
    SELECT id INTO selected FROM pgos_private.volumes WHERE name = volume_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'volume does not exist: %', volume_name USING ERRCODE = 'P0002';
    END IF;
    PERFORM set_config('pgos.volume_id', selected::text, false);
    RETURN selected;
END
$$;


--
-- Name: volumes(); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.volumes() RETURNS TABLE(id uuid, name text, created_at timestamp with time zone)
    LANGUAGE sql STABLE
    AS $$
    SELECT v.id, v.name, v.created_at
    FROM pgos_private.volumes v
    ORDER BY v.name COLLATE "C"
$$;


--
-- Name: walk(text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.walk(target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.walk(pgos.current_volume(), target_path)
$$;


--
-- Name: walk(uuid, text); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.walk(target_volume uuid, target_path text) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, mtime timestamp with time zone, generation bigint)
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM pgos.find_entries(target_volume, target_path, NULL, NULL)
$$;


--
-- Name: write_file(text, bytea, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.write_file(target_path text, data bytea, target_mode integer DEFAULT 420) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT pgos.write_file(pgos.current_volume(), target_path, data, target_mode)
$$;


--
-- Name: write_file(uuid, text, bytea, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.write_file(target_volume uuid, target_path text, data bytea, target_mode integer DEFAULT 420) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    result bigint;
    location record;
BEGIN
    result := pgos.write_file_inline(target_volume, target_path, data, target_mode);
    SELECT * INTO STRICT location
    FROM pgos_private.locate_zone(target_volume, target_path);
    PERFORM pgos_private.blockize_zone(target_volume, location.zone_id);
    PERFORM pgos_private.reclaim_content_segments(target_volume);
    RETURN result;
END
$$;


--
-- Name: write_file_entry(uuid, text, bytea, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.write_file_entry(target_volume uuid, target_path text, data bytea, target_mode integer DEFAULT 420) RETURNS TABLE(id bigint, path text, name text, kind smallint, mode integer, uid integer, gid integer, size bigint, atime timestamp with time zone, mtime timestamp with time zone, ctime timestamp with time zone, generation bigint, link_target text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM pgos.write_file(target_volume, target_path, data, target_mode);
    RETURN QUERY SELECT * FROM pgos.stat(target_volume, target_path);
END
$$;


--
-- Name: write_file_inline(uuid, text, bytea, integer); Type: FUNCTION; Schema: pgos; Owner: -
--

CREATE FUNCTION pgos.write_file_inline(target_volume uuid, target_path text, data bytea, target_mode integer DEFAULT 420) RETURNS bigint
    LANGUAGE plpgsql
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    clean_path text := pgos_private.assert_path(target_path);
    parent_location record;
    entry_relative_path text;
    decoded text := pgos_private.utf8_or_null(data);
    result bigint;
BEGIN
    IF pgos_private.kind_of(target_volume, pgos_private.parent_of(clean_path)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'parent directory does not exist: %', clean_path USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO STRICT parent_location
    FROM pgos_private.locate_zone(target_volume, pgos_private.parent_of(clean_path));
    entry_relative_path := CASE
        WHEN parent_location.relative_path = '' THEN pgos_private.name_of(clean_path)
        ELSE parent_location.relative_path || '/' || pgos_private.name_of(clean_path)
    END;

    INSERT INTO pgos_private.zone_entries (
        volume_id, zone_id, relative_path, parent_path, name, kind,
        text_content, binary_content, mode, size
    ) VALUES (
        target_volume, parent_location.zone_id, entry_relative_path,
        parent_location.relative_path, pgos_private.name_of(clean_path), 1,
        decoded, CASE WHEN decoded IS NULL THEN data ELSE NULL END,
        target_mode, octet_length(data)
    )
    ON CONFLICT (volume_id, zone_id, relative_path) DO UPDATE SET
        text_content = EXCLUDED.text_content,
        content_object = NULL,
        binary_content = EXCLUDED.binary_content,
        size = EXCLUDED.size,
        mtime = clock_timestamp(),
        ctime = clock_timestamp(),
        generation = pgos_private.zone_entries.generation + 1
    WHERE pgos_private.zone_entries.kind = 1
    RETURNING id INTO result;
    IF result IS NULL THEN
        RAISE EXCEPTION 'not a regular file: %', clean_path USING ERRCODE = '42809';
    END IF;
    RETURN result;
END
$$;


--
-- Name: absolute_path(text, text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.absolute_path(zone_path text, relative_path text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN relative_path = '' THEN zone_path
        WHEN zone_path = '/' THEN '/' || relative_path
        ELSE zone_path || '/' || relative_path
    END
$$;


--
-- Name: ancestor_paths(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.ancestor_paths(input_path text) RETURNS TABLE(path text)
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    WITH parts AS (
        SELECT string_to_array(trim(leading '/' FROM pgos_private.assert_path(input_path)), '/') AS value
    )
    SELECT CASE
        WHEN depth = 0 THEN '/'
        ELSE '/' || array_to_string(value[1:depth], '/')
    END
    FROM parts,
         generate_series(0, CASE WHEN input_path = '/' THEN 0 ELSE cardinality(value) END) AS depth
$$;


--
-- Name: assert_path(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.assert_path(input_path text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $_$
BEGIN
    IF input_path <> '/' AND (
        input_path !~ '^/[^/]+(/[^/]+)*$' OR
        input_path ~ '(^|/)\.\.?(/|$)'
    ) THEN
        RAISE EXCEPTION 'invalid normalized path: %', input_path USING ERRCODE = '22023';
    END IF;
    RETURN input_path;
END
$_$;


--
-- Name: blockize_zone(uuid, bigint); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.blockize_zone(target_volume uuid, target_zone bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    CREATE TEMPORARY TABLE pgos_content_mapping ON COMMIT DROP AS
    SELECT entry.id AS entry_id, gen_random_uuid() AS object_id
    FROM pgos_private.zone_entries entry
    WHERE entry.volume_id = target_volume
      AND entry.zone_id = target_zone
      AND entry.kind = 1
      AND entry.text_content IS NOT NULL
      AND entry.content_object IS NULL;

    INSERT INTO pgos_private.content_objects(id, volume_id, byte_size)
    SELECT mapping.object_id, target_volume, entry.size
    FROM pgos_content_mapping mapping
    JOIN pgos_private.zone_entries entry
      ON entry.volume_id = target_volume
     AND entry.zone_id = target_zone
     AND entry.id = mapping.entry_id;

    INSERT INTO pgos_private.content_blocks(
        object_id, volume_id, ordinal, byte_offset, first_line, body
    )
    SELECT mapping.object_id, target_volume, block.ordinal,
           block.byte_offset, block.first_line, block.body
    FROM pgos_content_mapping mapping
    JOIN pgos_private.zone_entries entry
      ON entry.volume_id = target_volume
     AND entry.zone_id = target_zone
     AND entry.id = mapping.entry_id
    CROSS JOIN LATERAL pgos_private.split_text_blocks(
        entry.text_content, 8192
    ) block;

    UPDATE pgos_private.zone_entries entry
    SET content_object = mapping.object_id,
        text_content = ''
    FROM pgos_content_mapping mapping
    WHERE entry.volume_id = target_volume
      AND entry.zone_id = target_zone
      AND entry.id = mapping.entry_id;
END
$$;


--
-- Name: blockize_zone_segment(uuid, bigint); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.blockize_zone_segment(target_volume uuid, target_zone bigint) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
    segment uuid := gen_random_uuid();
    stage_schema text := pgos_private.staging_schema(segment);
BEGIN
    PERFORM pgos_private.prepare_content_segment(target_volume, segment);

    CREATE TEMPORARY TABLE pgos_content_mapping ON COMMIT DROP AS
    SELECT entry.id AS entry_id, gen_random_uuid() AS object_id
    FROM pgos_private.zone_entries entry
    WHERE entry.volume_id = target_volume
      AND entry.zone_id = target_zone
      AND entry.kind = 1
      AND entry.text_content IS NOT NULL
      AND entry.content_object IS NULL;

    IF NOT EXISTS (SELECT 1 FROM pgos_content_mapping) THEN
        DELETE FROM pgos_private.content_segments WHERE id = segment;
        RETURN;
    END IF;

    INSERT INTO pgos_private.content_objects(
        id, volume_id, byte_size, segment_id
    )
    SELECT mapping.object_id, target_volume, entry.size, segment
    FROM pgos_content_mapping mapping
    JOIN pgos_private.zone_entries entry
      ON entry.volume_id = target_volume
     AND entry.zone_id = target_zone
     AND entry.id = mapping.entry_id;

    EXECUTE format(
        'INSERT INTO %I.content_segment(
             segment_id, object_id, volume_id, ordinal,
             byte_offset, first_line, body
         )
         SELECT $1, mapping.object_id, $2, block.ordinal,
                block.byte_offset, block.first_line, block.body
         FROM pgos_content_mapping mapping
         JOIN pgos_private.zone_entries entry
           ON entry.volume_id = $2
          AND entry.zone_id = $3
          AND entry.id = mapping.entry_id
         CROSS JOIN LATERAL pgos_private.split_text_blocks(
             entry.text_content, 8192
         ) block',
        stage_schema
    ) USING segment, target_volume, target_zone;

    UPDATE pgos_private.zone_entries entry
    SET content_object = mapping.object_id,
        text_content = ''
    FROM pgos_content_mapping mapping
    WHERE entry.volume_id = target_volume
      AND entry.zone_id = target_zone
      AND entry.id = mapping.entry_id;

    PERFORM pgos_private.publish_content_segment(target_volume, segment);
END
$_$;


--
-- Name: entry_bytes(text, bytea); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.entry_bytes(text_data text, binary_data bytea) RETURNS bytea
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE WHEN text_data IS NULL THEN binary_data ELSE convert_to(text_data, 'UTF8') END
$$;


--
-- Name: entry_bytes(text, bytea, uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.entry_bytes(content text, binary_data bytea, object_id uuid) RETURNS bytea
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF object_id IS NULL THEN
        RETURN pgos_private.entry_bytes(content, binary_data);
    END IF;
    IF (SELECT byte_size FROM pgos_private.content_objects WHERE id = object_id) > 134217728 THEN
        RAISE EXCEPTION 'large file requires the streaming or range API' USING ERRCODE = '54000';
    END IF;
    RETURN (SELECT convert_to(coalesce(string_agg(body, '' ORDER BY ordinal), ''), 'UTF8')
            FROM pgos_private.all_content_blocks b WHERE b.object_id = entry_bytes.object_id);
END
$$;


--
-- Name: file_content(uuid, text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.file_content(target_volume uuid, target_path text) RETURNS TABLE(object_id uuid, inline_text text)
    LANGUAGE plpgsql STABLE ROWS 1
    AS $$
DECLARE entry record;
BEGIN
    SELECT e.* INTO entry
    FROM pgos_private.locate_zone(target_volume, target_path) location
    JOIN pgos_private.zone_entries e ON e.volume_id = target_volume
        AND e.zone_id = location.zone_id AND e.relative_path = location.relative_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'file does not exist: %', target_path USING ERRCODE = 'P0002';
    END IF;
    IF entry.kind <> 1 OR entry.text_content IS NULL THEN
        RAISE EXCEPTION 'not a text file: %', target_path USING ERRCODE = '42809';
    END IF;
    RETURN QUERY SELECT entry.content_object, entry.text_content;
END
$$;


--
-- Name: kind_of(uuid, text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.kind_of(target_volume uuid, target_path text) RETURNS smallint
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
DECLARE
    location record;
    result smallint;
BEGIN
    SELECT * INTO location FROM pgos_private.locate_zone(target_volume, target_path);
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF location.relative_path = '' THEN RETURN 2; END IF;
    SELECT entry.kind INTO result
    FROM pgos_private.zone_entries entry
    WHERE entry.volume_id = target_volume AND entry.zone_id = location.zone_id
      AND entry.relative_path = location.relative_path;
    RETURN result;
END
$$;


--
-- Name: locate_zone(uuid, text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.locate_zone(target_volume uuid, target_path text) RETURNS TABLE(zone_id bigint, zone_path text, relative_path text)
    LANGUAGE sql STABLE
    AS $$
    SELECT z.id,
           z.path,
           CASE
               WHEN z.path = pgos_private.assert_path(target_path) THEN ''
               WHEN z.path = '/' THEN trim(leading '/' FROM pgos_private.assert_path(target_path))
               ELSE substr(pgos_private.assert_path(target_path), length(z.path) + 2)
           END
    FROM pgos_private.ancestor_paths(pgos_private.assert_path(target_path)) ancestor
    JOIN pgos_private.zones z
      ON z.volume_id = target_volume AND z.path = ancestor.path
    ORDER BY length(z.path) DESC
    LIMIT 1
$$;


--
-- Name: matching_content_blocks(uuid, text[]); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.matching_content_blocks(target_volume uuid, needles text[]) RETURNS TABLE(object_id uuid, ordinal bigint, first_line bigint, body text)
    LANGUAGE plpgsql STABLE
    SET plan_cache_mode TO 'force_custom_plan'
    AS $_$
DECLARE
    predicate text;
BEGIN
    IF needles IS NULL THEN
        RETURN QUERY
        SELECT block.object_id, block.ordinal, block.first_line, block.body
        FROM pgos_private.all_content_blocks block
        WHERE block.volume_id = target_volume;
        RETURN;
    END IF;
    IF cardinality(needles) = 0 THEN
        RETURN;
    END IF;

    SELECT string_agg(
        format('block.body LIKE $2[%s]', subscript), ' OR ' ORDER BY subscript
    )
    INTO STRICT predicate
    FROM generate_subscripts(needles, 1) subscript;

    RETURN QUERY EXECUTE format(
        'SELECT block.object_id, block.ordinal, block.first_line, block.body
         FROM pgos_private.all_content_blocks block
         WHERE block.volume_id = $1 AND (%s)',
        predicate
    ) USING target_volume, needles;
END
$_$;


--
-- Name: name_of(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.name_of(input_path text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN input_path = '/' THEN ''
        ELSE right(input_path, strpos(reverse(input_path), '/') - 1)
    END
$$;


--
-- Name: parent_of(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.parent_of(input_path text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN input_path = '/' THEN NULL
        WHEN strpos(substr(input_path, 2), '/') = 0 THEN '/'
        ELSE left(input_path, length(input_path) - strpos(reverse(input_path), '/'))
    END
$$;


--
-- Name: prepare_content_segment(uuid, uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.prepare_content_segment(target_volume uuid, segment uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    stage_schema text := pgos_private.staging_schema(segment);
    primary_index text := pgos_private.segment_relation(segment) || '_pkey';
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pgos_private.volumes WHERE id = target_volume
    ) THEN
        RAISE EXCEPTION 'volume does not exist: %', target_volume
            USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO pgos_private.content_segments(id, volume_id)
    VALUES (segment, target_volume);

    EXECUTE format('CREATE SCHEMA %I', stage_schema);
    EXECUTE format(
        'CREATE TABLE %I.content_segment
         (LIKE pgos_private.bulk_content_blocks
          INCLUDING STORAGE INCLUDING CONSTRAINTS)',
        stage_schema
    );
    EXECUTE format(
        'ALTER TABLE %I.content_segment
         ADD CONSTRAINT content_segment_volume_check
             CHECK (volume_id = %L::uuid),
         ADD CONSTRAINT content_segment_id_check
             CHECK (segment_id = %L::uuid),
         ADD CONSTRAINT %I
             PRIMARY KEY (object_id, ordinal)',
        stage_schema, target_volume, segment, primary_index
    );
    PERFORM set_config(
        'search_path',
        format('%I,pgos,pgos_private,public,pg_catalog', stage_schema),
        true
    );
END
$$;


--
-- Name: prepare_content_volume(uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.prepare_content_volume(target_volume uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    volume_table text := pgos_private.volume_relation(target_volume);
BEGIN
    IF to_regclass('pgos_private.' || volume_table) IS NULL THEN
        EXECUTE format(
            'CREATE TABLE pgos_private.%I
             PARTITION OF pgos_private.bulk_content_blocks
             FOR VALUES IN (%L) PARTITION BY LIST (segment_id)',
            volume_table, target_volume
        );
    END IF;
END
$$;


--
-- Name: publish_content_segment(uuid, uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.publish_content_segment(target_volume uuid, segment uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    volume_table text := pgos_private.volume_relation(target_volume);
    segment_table text := pgos_private.segment_relation(segment);
    stage_schema text := pgos_private.staging_schema(segment);
    object_index text := segment_table || '_object';
    mismatched boolean;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pgos_private.content_segments
        WHERE id = segment AND volume_id = target_volume AND NOT published
    ) THEN
        RAISE EXCEPTION 'content segment is not ready: %', segment
            USING ERRCODE = '55000';
    END IF;
    EXECUTE format(
        'SELECT EXISTS (
             SELECT 1 FROM %I.content_segment
             WHERE segment_id <> %L::uuid OR volume_id <> %L::uuid
         )',
        stage_schema, segment, target_volume
    ) INTO mismatched;
    IF mismatched THEN
        RAISE EXCEPTION 'content segment staging does not match'
            USING ERRCODE = '22023';
    END IF;

    EXECUTE format(
        'CREATE INDEX %I ON %I.content_segment(object_id, byte_offset)',
        object_index, stage_schema
    );
    EXECUTE format('ANALYZE %I.content_segment', stage_schema);

    IF to_regclass('pgos_private.' || volume_table) IS NULL THEN
        RAISE EXCEPTION 'content volume is not prepared: %', target_volume
            USING ERRCODE = '55000';
    END IF;

    EXECUTE format(
        'ALTER TABLE %I.content_segment SET SCHEMA pgos_private',
        stage_schema
    );
    EXECUTE format(
        'ALTER TABLE pgos_private.content_segment RENAME TO %I',
        segment_table
    );
    EXECUTE format('DROP SCHEMA %I', stage_schema);
    EXECUTE format(
        'ALTER TABLE pgos_private.%I ATTACH PARTITION pgos_private.%I
         FOR VALUES IN (%L)',
        volume_table, segment_table, segment
    );

    UPDATE pgos_private.content_segments
    SET published = true
    WHERE id = segment;
END
$$;


--
-- Name: reclaim_content_segments(uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.reclaim_content_segments(target_volume uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    segment record;
BEGIN
    FOR segment IN
        SELECT stored.id
        FROM pgos_private.content_segments stored
        WHERE stored.volume_id = target_volume
          AND stored.published
          AND NOT EXISTS (
              SELECT 1
              FROM pgos_private.content_objects object
              JOIN pgos_private.zone_entries entry
                ON entry.volume_id = target_volume
               AND entry.content_object = object.id
              WHERE object.segment_id = stored.id
          )
    LOOP
        EXECUTE format(
            'DROP TABLE pgos_private.%I',
            pgos_private.segment_relation(segment.id)
        );
        DELETE FROM pgos_private.content_objects
        WHERE segment_id = segment.id;
        DELETE FROM pgos_private.content_segments
        WHERE id = segment.id;
    END LOOP;
END
$$;


--
-- Name: relative_name(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.relative_name(input_path text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    SELECT right(input_path, strpos(reverse('/' || input_path), '/') - 1)
$$;


--
-- Name: relative_parent(text); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.relative_parent(input_path text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    SELECT CASE
        WHEN strpos(input_path, '/') = 0 THEN ''
        ELSE left(input_path, length(input_path) - strpos(reverse(input_path), '/'))
    END
$$;


--
-- Name: segment_relation(uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.segment_relation(segment uuid) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    SELECT 'content_segment_' || replace(segment::text, '-', '')
$$;


--
-- Name: split_text_blocks(text, integer); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.split_text_blocks(content text, target_bytes integer DEFAULT 131072) RETURNS TABLE(ordinal bigint, byte_offset bigint, first_line bigint, body text)
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
DECLARE
    remaining bytea := convert_to(content, 'UTF8');
    next_bytes bytea;
    next_body text;
    newline_offset integer;
    next_ordinal bigint := 0;
    next_byte_offset bigint := 0;
    next_first_line bigint := 1;
BEGIN
    IF target_bytes < 1 THEN
        RAISE EXCEPTION 'block size must be positive' USING ERRCODE = '22023';
    END IF;
    IF remaining = ''::bytea THEN
        RETURN;
    END IF;

    WHILE remaining <> ''::bytea LOOP
        IF octet_length(remaining) <= target_bytes THEN
            next_bytes := remaining;
            remaining := ''::bytea;
        ELSE
            newline_offset := position(
                E'\\x0a'::bytea IN substring(remaining FROM target_bytes + 1)
            );
            IF newline_offset = 0 THEN
                next_bytes := remaining;
                remaining := ''::bytea;
            ELSE
                newline_offset := target_bytes + newline_offset;
                next_bytes := substring(remaining FROM 1 FOR newline_offset);
                remaining := substring(remaining FROM newline_offset + 1);
            END IF;
        END IF;
        next_body := convert_from(next_bytes, 'UTF8');

        ordinal := next_ordinal;
        byte_offset := next_byte_offset;
        first_line := next_first_line;
        body := next_body;
        RETURN NEXT;

        next_ordinal := next_ordinal + 1;
        next_byte_offset := next_byte_offset + octet_length(next_body);
        next_first_line := next_first_line
            + length(next_body) - length(replace(next_body, E'\n', ''));
    END LOOP;
END
$$;


--
-- Name: staging_schema(uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.staging_schema(segment uuid) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    SELECT 'pgos_staging_' || replace(segment::text, '-', '')
$$;


--
-- Name: utf8_or_null(bytea); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.utf8_or_null(data bytea) RETURNS text
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
BEGIN
    RETURN convert_from(data, 'UTF8');
EXCEPTION WHEN character_not_in_repertoire THEN
    RETURN NULL;
END
$$;


--
-- Name: volume_relation(uuid); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.volume_relation(target_volume uuid) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
    SELECT 'content_volume_' || replace(target_volume::text, '-', '')
$$;


--
-- Name: zone_entries_after_delete(); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.zone_entries_after_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pgos_private.zones zone
    SET entry_count = zone.entry_count - removed.entry_count,
        file_bytes = zone.file_bytes - removed.file_bytes
    FROM (
        SELECT volume_id, zone_id, count(*) AS entry_count,
               COALESCE(sum(size) FILTER (WHERE kind = 1), 0) AS file_bytes
        FROM old_entries
        GROUP BY volume_id, zone_id
    ) removed
    WHERE zone.volume_id = removed.volume_id AND zone.id = removed.zone_id;
    RETURN NULL;
END
$$;


--
-- Name: zone_entries_after_insert(); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.zone_entries_after_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pgos_private.zones zone
    SET entry_count = zone.entry_count + added.entry_count,
        file_bytes = zone.file_bytes + added.file_bytes
    FROM (
        SELECT volume_id, zone_id, count(*) AS entry_count,
               COALESCE(sum(size) FILTER (WHERE kind = 1), 0) AS file_bytes
        FROM new_entries
        GROUP BY volume_id, zone_id
    ) added
    WHERE zone.volume_id = added.volume_id AND zone.id = added.zone_id;
    RETURN NULL;
END
$$;


--
-- Name: zone_entries_after_update(); Type: FUNCTION; Schema: pgos_private; Owner: -
--

CREATE FUNCTION pgos_private.zone_entries_after_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pgos_private.zones zone
    SET entry_count = zone.entry_count + changed.entry_delta,
        file_bytes = zone.file_bytes + changed.byte_delta
    FROM (
        SELECT volume_id, zone_id,
               sum(entry_delta)::bigint AS entry_delta,
               sum(byte_delta)::bigint AS byte_delta
        FROM (
            SELECT volume_id, zone_id, -count(*) AS entry_delta,
                   -COALESCE(sum(size) FILTER (WHERE kind = 1), 0) AS byte_delta
            FROM old_entries
            GROUP BY volume_id, zone_id
            UNION ALL
            SELECT volume_id, zone_id, count(*) AS entry_delta,
                   COALESCE(sum(size) FILTER (WHERE kind = 1), 0) AS byte_delta
            FROM new_entries
            GROUP BY volume_id, zone_id
        ) deltas
        GROUP BY volume_id, zone_id
        HAVING sum(entry_delta) <> 0 OR sum(byte_delta) <> 0
    ) changed
    WHERE zone.volume_id = changed.volume_id AND zone.id = changed.zone_id;
    RETURN NULL;
END
$$;


SET default_tablespace = '';

--
-- Name: bulk_content_blocks; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.bulk_content_blocks (
    segment_id uuid NOT NULL,
    object_id uuid NOT NULL,
    volume_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    byte_offset bigint NOT NULL,
    first_line bigint NOT NULL,
    body text NOT NULL,
    CONSTRAINT bulk_content_blocks_byte_offset_check CHECK ((byte_offset >= 0)),
    CONSTRAINT bulk_content_blocks_first_line_check CHECK ((first_line > 0)),
    CONSTRAINT bulk_content_blocks_ordinal_check CHECK ((ordinal >= 0))
)
PARTITION BY LIST (volume_id);


SET default_table_access_method = heap;

--
-- Name: content_blocks; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.content_blocks (
    object_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    byte_offset bigint NOT NULL,
    first_line bigint NOT NULL,
    body text NOT NULL,
    volume_id uuid NOT NULL,
    CONSTRAINT content_blocks_byte_offset_check CHECK ((byte_offset >= 0)),
    CONSTRAINT content_blocks_first_line_check CHECK ((first_line > 0)),
    CONSTRAINT content_blocks_ordinal_check CHECK ((ordinal >= 0))
);


--
-- Name: all_content_blocks; Type: VIEW; Schema: pgos_private; Owner: -
--

CREATE VIEW pgos_private.all_content_blocks AS
 SELECT block.object_id,
    block.ordinal,
    block.byte_offset,
    block.first_line,
    block.body,
    block.volume_id,
    NULL::uuid AS segment_id
   FROM pgos_private.content_blocks block
UNION ALL
 SELECT block.object_id,
    block.ordinal,
    block.byte_offset,
    block.first_line,
    block.body,
    block.volume_id,
    block.segment_id
   FROM pgos_private.bulk_content_blocks block;


--
-- Name: content_block_terms; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.content_block_terms (
    object_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    terms tsvector NOT NULL,
    max_ascii_letters integer NOT NULL,
    CONSTRAINT content_block_terms_max_ascii_letters_check CHECK ((max_ascii_letters >= 0))
);


--
-- Name: content_objects; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.content_objects (
    id uuid NOT NULL,
    volume_id uuid NOT NULL,
    byte_size bigint DEFAULT 0 NOT NULL,
    segment_id uuid,
    CONSTRAINT content_objects_byte_size_check CHECK ((byte_size >= 0))
);


--
-- Name: content_segments; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.content_segments (
    id uuid NOT NULL,
    volume_id uuid NOT NULL,
    published boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: node_id_seq; Type: SEQUENCE; Schema: pgos_private; Owner: -
--

CREATE SEQUENCE pgos_private.node_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: volumes; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.volumes (
    id uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: zone_entries; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
)
PARTITION BY HASH (volume_id, zone_id);


--
-- Name: zone_entries_0; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_0 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_1; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_1 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_10; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_10 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_11; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_11 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_12; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_12 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_13; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_13 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_14; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_14 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_15; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_15 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_16; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_16 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_17; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_17 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_18; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_18 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_19; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_19 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_2; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_2 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_20; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_20 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_21; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_21 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_22; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_22 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_23; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_23 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_24; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_24 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_25; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_25 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_26; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_26 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_27; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_27 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_28; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_28 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_29; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_29 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_3; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_3 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_30; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_30 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_31; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_31 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_4; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_4 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_5; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_5 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_6; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_6 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_7; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_7 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_8; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_8 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zone_entries_9; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zone_entries_9 (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    zone_id bigint NOT NULL,
    relative_path text NOT NULL COLLATE pg_catalog."C",
    parent_path text NOT NULL COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    kind smallint NOT NULL,
    text_content text,
    binary_content bytea,
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    link_target text,
    generation bigint DEFAULT 1 NOT NULL,
    content_object uuid,
    CONSTRAINT zone_entries_check CHECK (((relative_path <> ''::text) AND (name <> ''::text))),
    CONSTRAINT zone_entries_check1 CHECK ((((kind = 1) AND (num_nonnulls(text_content, binary_content) = 1) AND (link_target IS NULL)) OR ((kind = 2) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NULL)) OR ((kind = 3) AND (text_content IS NULL) AND (binary_content IS NULL) AND (link_target IS NOT NULL)))),
    CONSTRAINT zone_entries_kind_check CHECK ((kind = ANY (ARRAY[1, 2, 3]))),
    CONSTRAINT zone_entries_size_check CHECK ((size >= 0))
);


--
-- Name: zones; Type: TABLE; Schema: pgos_private; Owner: -
--

CREATE TABLE pgos_private.zones (
    id bigint DEFAULT nextval('pgos_private.node_id_seq'::regclass) NOT NULL,
    volume_id uuid NOT NULL,
    path text NOT NULL COLLATE pg_catalog."C",
    parent_zone_id bigint,
    parent_path text COLLATE pg_catalog."C",
    name text NOT NULL COLLATE pg_catalog."C",
    mode integer NOT NULL,
    uid integer DEFAULT 0 NOT NULL,
    gid integer DEFAULT 0 NOT NULL,
    atime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    mtime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    ctime timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    entry_count bigint DEFAULT 0 NOT NULL,
    file_bytes bigint DEFAULT 0 NOT NULL,
    CONSTRAINT zones_check CHECK ((((path = '/'::text) AND (parent_zone_id IS NULL) AND (parent_path IS NULL) AND (name = ''::text)) OR ((path <> '/'::text) AND (parent_zone_id IS NOT NULL) AND (parent_path IS NOT NULL) AND (name <> ''::text))))
);


--
-- Name: zone_entries_0; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_0 FOR VALUES WITH (modulus 32, remainder 0);


--
-- Name: zone_entries_1; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_1 FOR VALUES WITH (modulus 32, remainder 1);


--
-- Name: zone_entries_10; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_10 FOR VALUES WITH (modulus 32, remainder 10);


--
-- Name: zone_entries_11; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_11 FOR VALUES WITH (modulus 32, remainder 11);


--
-- Name: zone_entries_12; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_12 FOR VALUES WITH (modulus 32, remainder 12);


--
-- Name: zone_entries_13; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_13 FOR VALUES WITH (modulus 32, remainder 13);


--
-- Name: zone_entries_14; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_14 FOR VALUES WITH (modulus 32, remainder 14);


--
-- Name: zone_entries_15; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_15 FOR VALUES WITH (modulus 32, remainder 15);


--
-- Name: zone_entries_16; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_16 FOR VALUES WITH (modulus 32, remainder 16);


--
-- Name: zone_entries_17; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_17 FOR VALUES WITH (modulus 32, remainder 17);


--
-- Name: zone_entries_18; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_18 FOR VALUES WITH (modulus 32, remainder 18);


--
-- Name: zone_entries_19; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_19 FOR VALUES WITH (modulus 32, remainder 19);


--
-- Name: zone_entries_2; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_2 FOR VALUES WITH (modulus 32, remainder 2);


--
-- Name: zone_entries_20; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_20 FOR VALUES WITH (modulus 32, remainder 20);


--
-- Name: zone_entries_21; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_21 FOR VALUES WITH (modulus 32, remainder 21);


--
-- Name: zone_entries_22; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_22 FOR VALUES WITH (modulus 32, remainder 22);


--
-- Name: zone_entries_23; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_23 FOR VALUES WITH (modulus 32, remainder 23);


--
-- Name: zone_entries_24; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_24 FOR VALUES WITH (modulus 32, remainder 24);


--
-- Name: zone_entries_25; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_25 FOR VALUES WITH (modulus 32, remainder 25);


--
-- Name: zone_entries_26; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_26 FOR VALUES WITH (modulus 32, remainder 26);


--
-- Name: zone_entries_27; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_27 FOR VALUES WITH (modulus 32, remainder 27);


--
-- Name: zone_entries_28; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_28 FOR VALUES WITH (modulus 32, remainder 28);


--
-- Name: zone_entries_29; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_29 FOR VALUES WITH (modulus 32, remainder 29);


--
-- Name: zone_entries_3; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_3 FOR VALUES WITH (modulus 32, remainder 3);


--
-- Name: zone_entries_30; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_30 FOR VALUES WITH (modulus 32, remainder 30);


--
-- Name: zone_entries_31; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_31 FOR VALUES WITH (modulus 32, remainder 31);


--
-- Name: zone_entries_4; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_4 FOR VALUES WITH (modulus 32, remainder 4);


--
-- Name: zone_entries_5; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_5 FOR VALUES WITH (modulus 32, remainder 5);


--
-- Name: zone_entries_6; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_6 FOR VALUES WITH (modulus 32, remainder 6);


--
-- Name: zone_entries_7; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_7 FOR VALUES WITH (modulus 32, remainder 7);


--
-- Name: zone_entries_8; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_8 FOR VALUES WITH (modulus 32, remainder 8);


--
-- Name: zone_entries_9; Type: TABLE ATTACH; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries ATTACH PARTITION pgos_private.zone_entries_9 FOR VALUES WITH (modulus 32, remainder 9);


--
-- Name: content_block_terms content_block_terms_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_block_terms
    ADD CONSTRAINT content_block_terms_pkey PRIMARY KEY (object_id, ordinal);


--
-- Name: content_blocks content_blocks_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_blocks
    ADD CONSTRAINT content_blocks_pkey PRIMARY KEY (object_id, ordinal);


--
-- Name: content_objects content_objects_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_objects
    ADD CONSTRAINT content_objects_pkey PRIMARY KEY (id);


--
-- Name: content_segments content_segments_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_segments
    ADD CONSTRAINT content_segments_pkey PRIMARY KEY (id);


--
-- Name: volumes volumes_name_key; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.volumes
    ADD CONSTRAINT volumes_name_key UNIQUE (name);


--
-- Name: volumes volumes_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.volumes
    ADD CONSTRAINT volumes_pkey PRIMARY KEY (id);


--
-- Name: zone_entries zone_entries_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries
    ADD CONSTRAINT zone_entries_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_0 zone_entries_0_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_0
    ADD CONSTRAINT zone_entries_0_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_10 zone_entries_10_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_10
    ADD CONSTRAINT zone_entries_10_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_11 zone_entries_11_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_11
    ADD CONSTRAINT zone_entries_11_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_12 zone_entries_12_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_12
    ADD CONSTRAINT zone_entries_12_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_13 zone_entries_13_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_13
    ADD CONSTRAINT zone_entries_13_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_14 zone_entries_14_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_14
    ADD CONSTRAINT zone_entries_14_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_15 zone_entries_15_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_15
    ADD CONSTRAINT zone_entries_15_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_16 zone_entries_16_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_16
    ADD CONSTRAINT zone_entries_16_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_17 zone_entries_17_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_17
    ADD CONSTRAINT zone_entries_17_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_18 zone_entries_18_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_18
    ADD CONSTRAINT zone_entries_18_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_19 zone_entries_19_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_19
    ADD CONSTRAINT zone_entries_19_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_1 zone_entries_1_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_1
    ADD CONSTRAINT zone_entries_1_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_20 zone_entries_20_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_20
    ADD CONSTRAINT zone_entries_20_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_21 zone_entries_21_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_21
    ADD CONSTRAINT zone_entries_21_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_22 zone_entries_22_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_22
    ADD CONSTRAINT zone_entries_22_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_23 zone_entries_23_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_23
    ADD CONSTRAINT zone_entries_23_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_24 zone_entries_24_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_24
    ADD CONSTRAINT zone_entries_24_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_25 zone_entries_25_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_25
    ADD CONSTRAINT zone_entries_25_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_26 zone_entries_26_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_26
    ADD CONSTRAINT zone_entries_26_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_27 zone_entries_27_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_27
    ADD CONSTRAINT zone_entries_27_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_28 zone_entries_28_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_28
    ADD CONSTRAINT zone_entries_28_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_29 zone_entries_29_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_29
    ADD CONSTRAINT zone_entries_29_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_2 zone_entries_2_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_2
    ADD CONSTRAINT zone_entries_2_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_30 zone_entries_30_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_30
    ADD CONSTRAINT zone_entries_30_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_31 zone_entries_31_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_31
    ADD CONSTRAINT zone_entries_31_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_3 zone_entries_3_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_3
    ADD CONSTRAINT zone_entries_3_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_4 zone_entries_4_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_4
    ADD CONSTRAINT zone_entries_4_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_5 zone_entries_5_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_5
    ADD CONSTRAINT zone_entries_5_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_6 zone_entries_6_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_6
    ADD CONSTRAINT zone_entries_6_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_7 zone_entries_7_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_7
    ADD CONSTRAINT zone_entries_7_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_8 zone_entries_8_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_8
    ADD CONSTRAINT zone_entries_8_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zone_entries_9 zone_entries_9_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zone_entries_9
    ADD CONSTRAINT zone_entries_9_pkey PRIMARY KEY (volume_id, zone_id, id);


--
-- Name: zones zones_pkey; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zones
    ADD CONSTRAINT zones_pkey PRIMARY KEY (id);


--
-- Name: zones zones_volume_id_path_key; Type: CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zones
    ADD CONSTRAINT zones_volume_id_path_key UNIQUE (volume_id, path);


--
-- Name: content_block_terms_ascii_length; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX content_block_terms_ascii_length ON pgos_private.content_block_terms USING btree (object_id, max_ascii_letters, ordinal);


--
-- Name: content_block_terms_gin; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX content_block_terms_gin ON pgos_private.content_block_terms USING gin (terms);


--
-- Name: content_blocks_offset; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX content_blocks_offset ON pgos_private.content_blocks USING btree (object_id, byte_offset);


--
-- Name: content_objects_id_volume; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX content_objects_id_volume ON pgos_private.content_objects USING btree (id, volume_id);


--
-- Name: zone_entries_content_objects; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_content_objects ON ONLY pgos_private.zone_entries USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_0_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_0_volume_id_content_object_idx ON pgos_private.zone_entries_0 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_inode_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_inode_idx ON ONLY pgos_private.zone_entries USING btree (volume_id, id);


--
-- Name: zone_entries_0_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_0_volume_id_id_idx ON pgos_private.zone_entries_0 USING btree (volume_id, id);


--
-- Name: zone_entries_parent_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_parent_idx ON ONLY pgos_private.zone_entries USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_0_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_0_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_0 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_path_cover_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_path_cover_idx ON ONLY pgos_private.zone_entries USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_0_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_0_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_0 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_10_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_10_volume_id_content_object_idx ON pgos_private.zone_entries_10 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_10_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_10_volume_id_id_idx ON pgos_private.zone_entries_10 USING btree (volume_id, id);


--
-- Name: zone_entries_10_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_10_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_10 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_10_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_10_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_10 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_11_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_11_volume_id_content_object_idx ON pgos_private.zone_entries_11 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_11_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_11_volume_id_id_idx ON pgos_private.zone_entries_11 USING btree (volume_id, id);


--
-- Name: zone_entries_11_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_11_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_11 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_11_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_11_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_11 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_12_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_12_volume_id_content_object_idx ON pgos_private.zone_entries_12 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_12_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_12_volume_id_id_idx ON pgos_private.zone_entries_12 USING btree (volume_id, id);


--
-- Name: zone_entries_12_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_12_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_12 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_12_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_12_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_12 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_13_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_13_volume_id_content_object_idx ON pgos_private.zone_entries_13 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_13_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_13_volume_id_id_idx ON pgos_private.zone_entries_13 USING btree (volume_id, id);


--
-- Name: zone_entries_13_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_13_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_13 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_13_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_13_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_13 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_14_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_14_volume_id_content_object_idx ON pgos_private.zone_entries_14 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_14_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_14_volume_id_id_idx ON pgos_private.zone_entries_14 USING btree (volume_id, id);


--
-- Name: zone_entries_14_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_14_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_14 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_14_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_14_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_14 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_15_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_15_volume_id_content_object_idx ON pgos_private.zone_entries_15 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_15_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_15_volume_id_id_idx ON pgos_private.zone_entries_15 USING btree (volume_id, id);


--
-- Name: zone_entries_15_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_15_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_15 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_15_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_15_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_15 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_16_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_16_volume_id_content_object_idx ON pgos_private.zone_entries_16 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_16_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_16_volume_id_id_idx ON pgos_private.zone_entries_16 USING btree (volume_id, id);


--
-- Name: zone_entries_16_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_16_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_16 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_16_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_16_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_16 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_17_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_17_volume_id_content_object_idx ON pgos_private.zone_entries_17 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_17_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_17_volume_id_id_idx ON pgos_private.zone_entries_17 USING btree (volume_id, id);


--
-- Name: zone_entries_17_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_17_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_17 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_17_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_17_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_17 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_18_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_18_volume_id_content_object_idx ON pgos_private.zone_entries_18 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_18_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_18_volume_id_id_idx ON pgos_private.zone_entries_18 USING btree (volume_id, id);


--
-- Name: zone_entries_18_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_18_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_18 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_18_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_18_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_18 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_19_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_19_volume_id_content_object_idx ON pgos_private.zone_entries_19 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_19_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_19_volume_id_id_idx ON pgos_private.zone_entries_19 USING btree (volume_id, id);


--
-- Name: zone_entries_19_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_19_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_19 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_19_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_19_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_19 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_1_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_1_volume_id_content_object_idx ON pgos_private.zone_entries_1 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_1_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_1_volume_id_id_idx ON pgos_private.zone_entries_1 USING btree (volume_id, id);


--
-- Name: zone_entries_1_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_1_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_1 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_1_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_1_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_1 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_20_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_20_volume_id_content_object_idx ON pgos_private.zone_entries_20 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_20_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_20_volume_id_id_idx ON pgos_private.zone_entries_20 USING btree (volume_id, id);


--
-- Name: zone_entries_20_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_20_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_20 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_20_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_20_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_20 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_21_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_21_volume_id_content_object_idx ON pgos_private.zone_entries_21 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_21_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_21_volume_id_id_idx ON pgos_private.zone_entries_21 USING btree (volume_id, id);


--
-- Name: zone_entries_21_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_21_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_21 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_21_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_21_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_21 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_22_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_22_volume_id_content_object_idx ON pgos_private.zone_entries_22 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_22_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_22_volume_id_id_idx ON pgos_private.zone_entries_22 USING btree (volume_id, id);


--
-- Name: zone_entries_22_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_22_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_22 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_22_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_22_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_22 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_23_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_23_volume_id_content_object_idx ON pgos_private.zone_entries_23 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_23_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_23_volume_id_id_idx ON pgos_private.zone_entries_23 USING btree (volume_id, id);


--
-- Name: zone_entries_23_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_23_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_23 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_23_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_23_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_23 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_24_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_24_volume_id_content_object_idx ON pgos_private.zone_entries_24 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_24_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_24_volume_id_id_idx ON pgos_private.zone_entries_24 USING btree (volume_id, id);


--
-- Name: zone_entries_24_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_24_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_24 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_24_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_24_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_24 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_25_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_25_volume_id_content_object_idx ON pgos_private.zone_entries_25 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_25_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_25_volume_id_id_idx ON pgos_private.zone_entries_25 USING btree (volume_id, id);


--
-- Name: zone_entries_25_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_25_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_25 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_25_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_25_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_25 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_26_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_26_volume_id_content_object_idx ON pgos_private.zone_entries_26 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_26_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_26_volume_id_id_idx ON pgos_private.zone_entries_26 USING btree (volume_id, id);


--
-- Name: zone_entries_26_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_26_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_26 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_26_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_26_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_26 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_27_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_27_volume_id_content_object_idx ON pgos_private.zone_entries_27 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_27_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_27_volume_id_id_idx ON pgos_private.zone_entries_27 USING btree (volume_id, id);


--
-- Name: zone_entries_27_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_27_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_27 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_27_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_27_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_27 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_28_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_28_volume_id_content_object_idx ON pgos_private.zone_entries_28 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_28_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_28_volume_id_id_idx ON pgos_private.zone_entries_28 USING btree (volume_id, id);


--
-- Name: zone_entries_28_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_28_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_28 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_28_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_28_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_28 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_29_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_29_volume_id_content_object_idx ON pgos_private.zone_entries_29 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_29_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_29_volume_id_id_idx ON pgos_private.zone_entries_29 USING btree (volume_id, id);


--
-- Name: zone_entries_29_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_29_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_29 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_29_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_29_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_29 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_2_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_2_volume_id_content_object_idx ON pgos_private.zone_entries_2 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_2_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_2_volume_id_id_idx ON pgos_private.zone_entries_2 USING btree (volume_id, id);


--
-- Name: zone_entries_2_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_2_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_2 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_2_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_2_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_2 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_30_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_30_volume_id_content_object_idx ON pgos_private.zone_entries_30 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_30_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_30_volume_id_id_idx ON pgos_private.zone_entries_30 USING btree (volume_id, id);


--
-- Name: zone_entries_30_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_30_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_30 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_30_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_30_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_30 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_31_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_31_volume_id_content_object_idx ON pgos_private.zone_entries_31 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_31_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_31_volume_id_id_idx ON pgos_private.zone_entries_31 USING btree (volume_id, id);


--
-- Name: zone_entries_31_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_31_volume_id_zone_id_parent_path_name_id_kind__idx ON pgos_private.zone_entries_31 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_31_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_31_volume_id_zone_id_relative_path_name_kind_s_idx ON pgos_private.zone_entries_31 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_3_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_3_volume_id_content_object_idx ON pgos_private.zone_entries_3 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_3_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_3_volume_id_id_idx ON pgos_private.zone_entries_3 USING btree (volume_id, id);


--
-- Name: zone_entries_3_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_3_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_3 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_3_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_3_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_3 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_4_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_4_volume_id_content_object_idx ON pgos_private.zone_entries_4 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_4_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_4_volume_id_id_idx ON pgos_private.zone_entries_4 USING btree (volume_id, id);


--
-- Name: zone_entries_4_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_4_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_4 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_4_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_4_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_4 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_5_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_5_volume_id_content_object_idx ON pgos_private.zone_entries_5 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_5_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_5_volume_id_id_idx ON pgos_private.zone_entries_5 USING btree (volume_id, id);


--
-- Name: zone_entries_5_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_5_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_5 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_5_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_5_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_5 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_6_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_6_volume_id_content_object_idx ON pgos_private.zone_entries_6 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_6_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_6_volume_id_id_idx ON pgos_private.zone_entries_6 USING btree (volume_id, id);


--
-- Name: zone_entries_6_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_6_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_6 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_6_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_6_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_6 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_7_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_7_volume_id_content_object_idx ON pgos_private.zone_entries_7 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_7_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_7_volume_id_id_idx ON pgos_private.zone_entries_7 USING btree (volume_id, id);


--
-- Name: zone_entries_7_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_7_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_7 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_7_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_7_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_7 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_8_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_8_volume_id_content_object_idx ON pgos_private.zone_entries_8 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_8_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_8_volume_id_id_idx ON pgos_private.zone_entries_8 USING btree (volume_id, id);


--
-- Name: zone_entries_8_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_8_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_8 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_8_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_8_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_8 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zone_entries_9_volume_id_content_object_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_9_volume_id_content_object_idx ON pgos_private.zone_entries_9 USING btree (volume_id, content_object) WHERE (content_object IS NOT NULL);


--
-- Name: zone_entries_9_volume_id_id_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE INDEX zone_entries_9_volume_id_id_idx ON pgos_private.zone_entries_9 USING btree (volume_id, id);


--
-- Name: zone_entries_9_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_9_volume_id_zone_id_parent_path_name_id_kind_m_idx ON pgos_private.zone_entries_9 USING btree (volume_id, zone_id, parent_path, name) INCLUDE (id, kind, mode, uid, gid, size, mtime, generation);


--
-- Name: zone_entries_9_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zone_entries_9_volume_id_zone_id_relative_path_name_kind_si_idx ON pgos_private.zone_entries_9 USING btree (volume_id, zone_id, relative_path) INCLUDE (name, kind, size);


--
-- Name: zones_parent_name_idx; Type: INDEX; Schema: pgos_private; Owner: -
--

CREATE UNIQUE INDEX zones_parent_name_idx ON pgos_private.zones USING btree (volume_id, parent_zone_id, parent_path, name) WHERE (parent_zone_id IS NOT NULL);


--
-- Name: zone_entries_0_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_0_pkey;


--
-- Name: zone_entries_0_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_0_volume_id_content_object_idx;


--
-- Name: zone_entries_0_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_0_volume_id_id_idx;


--
-- Name: zone_entries_0_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_0_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_0_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_0_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_10_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_10_pkey;


--
-- Name: zone_entries_10_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_10_volume_id_content_object_idx;


--
-- Name: zone_entries_10_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_10_volume_id_id_idx;


--
-- Name: zone_entries_10_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_10_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_10_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_10_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_11_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_11_pkey;


--
-- Name: zone_entries_11_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_11_volume_id_content_object_idx;


--
-- Name: zone_entries_11_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_11_volume_id_id_idx;


--
-- Name: zone_entries_11_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_11_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_11_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_11_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_12_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_12_pkey;


--
-- Name: zone_entries_12_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_12_volume_id_content_object_idx;


--
-- Name: zone_entries_12_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_12_volume_id_id_idx;


--
-- Name: zone_entries_12_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_12_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_12_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_12_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_13_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_13_pkey;


--
-- Name: zone_entries_13_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_13_volume_id_content_object_idx;


--
-- Name: zone_entries_13_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_13_volume_id_id_idx;


--
-- Name: zone_entries_13_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_13_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_13_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_13_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_14_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_14_pkey;


--
-- Name: zone_entries_14_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_14_volume_id_content_object_idx;


--
-- Name: zone_entries_14_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_14_volume_id_id_idx;


--
-- Name: zone_entries_14_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_14_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_14_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_14_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_15_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_15_pkey;


--
-- Name: zone_entries_15_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_15_volume_id_content_object_idx;


--
-- Name: zone_entries_15_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_15_volume_id_id_idx;


--
-- Name: zone_entries_15_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_15_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_15_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_15_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_16_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_16_pkey;


--
-- Name: zone_entries_16_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_16_volume_id_content_object_idx;


--
-- Name: zone_entries_16_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_16_volume_id_id_idx;


--
-- Name: zone_entries_16_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_16_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_16_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_16_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_17_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_17_pkey;


--
-- Name: zone_entries_17_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_17_volume_id_content_object_idx;


--
-- Name: zone_entries_17_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_17_volume_id_id_idx;


--
-- Name: zone_entries_17_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_17_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_17_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_17_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_18_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_18_pkey;


--
-- Name: zone_entries_18_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_18_volume_id_content_object_idx;


--
-- Name: zone_entries_18_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_18_volume_id_id_idx;


--
-- Name: zone_entries_18_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_18_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_18_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_18_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_19_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_19_pkey;


--
-- Name: zone_entries_19_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_19_volume_id_content_object_idx;


--
-- Name: zone_entries_19_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_19_volume_id_id_idx;


--
-- Name: zone_entries_19_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_19_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_19_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_19_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_1_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_1_pkey;


--
-- Name: zone_entries_1_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_1_volume_id_content_object_idx;


--
-- Name: zone_entries_1_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_1_volume_id_id_idx;


--
-- Name: zone_entries_1_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_1_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_1_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_1_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_20_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_20_pkey;


--
-- Name: zone_entries_20_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_20_volume_id_content_object_idx;


--
-- Name: zone_entries_20_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_20_volume_id_id_idx;


--
-- Name: zone_entries_20_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_20_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_20_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_20_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_21_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_21_pkey;


--
-- Name: zone_entries_21_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_21_volume_id_content_object_idx;


--
-- Name: zone_entries_21_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_21_volume_id_id_idx;


--
-- Name: zone_entries_21_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_21_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_21_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_21_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_22_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_22_pkey;


--
-- Name: zone_entries_22_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_22_volume_id_content_object_idx;


--
-- Name: zone_entries_22_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_22_volume_id_id_idx;


--
-- Name: zone_entries_22_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_22_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_22_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_22_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_23_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_23_pkey;


--
-- Name: zone_entries_23_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_23_volume_id_content_object_idx;


--
-- Name: zone_entries_23_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_23_volume_id_id_idx;


--
-- Name: zone_entries_23_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_23_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_23_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_23_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_24_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_24_pkey;


--
-- Name: zone_entries_24_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_24_volume_id_content_object_idx;


--
-- Name: zone_entries_24_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_24_volume_id_id_idx;


--
-- Name: zone_entries_24_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_24_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_24_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_24_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_25_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_25_pkey;


--
-- Name: zone_entries_25_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_25_volume_id_content_object_idx;


--
-- Name: zone_entries_25_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_25_volume_id_id_idx;


--
-- Name: zone_entries_25_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_25_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_25_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_25_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_26_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_26_pkey;


--
-- Name: zone_entries_26_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_26_volume_id_content_object_idx;


--
-- Name: zone_entries_26_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_26_volume_id_id_idx;


--
-- Name: zone_entries_26_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_26_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_26_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_26_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_27_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_27_pkey;


--
-- Name: zone_entries_27_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_27_volume_id_content_object_idx;


--
-- Name: zone_entries_27_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_27_volume_id_id_idx;


--
-- Name: zone_entries_27_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_27_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_27_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_27_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_28_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_28_pkey;


--
-- Name: zone_entries_28_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_28_volume_id_content_object_idx;


--
-- Name: zone_entries_28_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_28_volume_id_id_idx;


--
-- Name: zone_entries_28_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_28_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_28_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_28_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_29_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_29_pkey;


--
-- Name: zone_entries_29_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_29_volume_id_content_object_idx;


--
-- Name: zone_entries_29_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_29_volume_id_id_idx;


--
-- Name: zone_entries_29_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_29_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_29_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_29_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_2_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_2_pkey;


--
-- Name: zone_entries_2_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_2_volume_id_content_object_idx;


--
-- Name: zone_entries_2_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_2_volume_id_id_idx;


--
-- Name: zone_entries_2_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_2_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_2_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_2_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_30_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_30_pkey;


--
-- Name: zone_entries_30_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_30_volume_id_content_object_idx;


--
-- Name: zone_entries_30_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_30_volume_id_id_idx;


--
-- Name: zone_entries_30_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_30_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_30_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_30_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_31_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_31_pkey;


--
-- Name: zone_entries_31_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_31_volume_id_content_object_idx;


--
-- Name: zone_entries_31_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_31_volume_id_id_idx;


--
-- Name: zone_entries_31_volume_id_zone_id_parent_path_name_id_kind__idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_31_volume_id_zone_id_parent_path_name_id_kind__idx;


--
-- Name: zone_entries_31_volume_id_zone_id_relative_path_name_kind_s_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_31_volume_id_zone_id_relative_path_name_kind_s_idx;


--
-- Name: zone_entries_3_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_3_pkey;


--
-- Name: zone_entries_3_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_3_volume_id_content_object_idx;


--
-- Name: zone_entries_3_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_3_volume_id_id_idx;


--
-- Name: zone_entries_3_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_3_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_3_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_3_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_4_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_4_pkey;


--
-- Name: zone_entries_4_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_4_volume_id_content_object_idx;


--
-- Name: zone_entries_4_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_4_volume_id_id_idx;


--
-- Name: zone_entries_4_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_4_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_4_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_4_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_5_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_5_pkey;


--
-- Name: zone_entries_5_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_5_volume_id_content_object_idx;


--
-- Name: zone_entries_5_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_5_volume_id_id_idx;


--
-- Name: zone_entries_5_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_5_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_5_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_5_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_6_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_6_pkey;


--
-- Name: zone_entries_6_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_6_volume_id_content_object_idx;


--
-- Name: zone_entries_6_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_6_volume_id_id_idx;


--
-- Name: zone_entries_6_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_6_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_6_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_6_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_7_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_7_pkey;


--
-- Name: zone_entries_7_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_7_volume_id_content_object_idx;


--
-- Name: zone_entries_7_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_7_volume_id_id_idx;


--
-- Name: zone_entries_7_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_7_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_7_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_7_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_8_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_8_pkey;


--
-- Name: zone_entries_8_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_8_volume_id_content_object_idx;


--
-- Name: zone_entries_8_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_8_volume_id_id_idx;


--
-- Name: zone_entries_8_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_8_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_8_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_8_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries_9_pkey; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_pkey ATTACH PARTITION pgos_private.zone_entries_9_pkey;


--
-- Name: zone_entries_9_volume_id_content_object_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_content_objects ATTACH PARTITION pgos_private.zone_entries_9_volume_id_content_object_idx;


--
-- Name: zone_entries_9_volume_id_id_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_inode_idx ATTACH PARTITION pgos_private.zone_entries_9_volume_id_id_idx;


--
-- Name: zone_entries_9_volume_id_zone_id_parent_path_name_id_kind_m_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_parent_idx ATTACH PARTITION pgos_private.zone_entries_9_volume_id_zone_id_parent_path_name_id_kind_m_idx;


--
-- Name: zone_entries_9_volume_id_zone_id_relative_path_name_kind_si_idx; Type: INDEX ATTACH; Schema: pgos_private; Owner: -
--

ALTER INDEX pgos_private.zone_entries_path_cover_idx ATTACH PARTITION pgos_private.zone_entries_9_volume_id_zone_id_relative_path_name_kind_si_idx;


--
-- Name: zone_entries zone_entries_count_delete; Type: TRIGGER; Schema: pgos_private; Owner: -
--

CREATE TRIGGER zone_entries_count_delete AFTER DELETE ON pgos_private.zone_entries REFERENCING OLD TABLE AS old_entries FOR EACH STATEMENT EXECUTE FUNCTION pgos_private.zone_entries_after_delete();


--
-- Name: zone_entries zone_entries_count_insert; Type: TRIGGER; Schema: pgos_private; Owner: -
--

CREATE TRIGGER zone_entries_count_insert AFTER INSERT ON pgos_private.zone_entries REFERENCING NEW TABLE AS new_entries FOR EACH STATEMENT EXECUTE FUNCTION pgos_private.zone_entries_after_insert();


--
-- Name: zone_entries zone_entries_count_update; Type: TRIGGER; Schema: pgos_private; Owner: -
--

CREATE TRIGGER zone_entries_count_update AFTER UPDATE ON pgos_private.zone_entries REFERENCING OLD TABLE AS old_entries NEW TABLE AS new_entries FOR EACH STATEMENT EXECUTE FUNCTION pgos_private.zone_entries_after_update();


--
-- Name: content_block_terms content_block_terms_object_id_ordinal_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_block_terms
    ADD CONSTRAINT content_block_terms_object_id_ordinal_fkey FOREIGN KEY (object_id, ordinal) REFERENCES pgos_private.content_blocks(object_id, ordinal) ON DELETE CASCADE;


--
-- Name: content_blocks content_blocks_object_id_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_blocks
    ADD CONSTRAINT content_blocks_object_id_fkey FOREIGN KEY (object_id) REFERENCES pgos_private.content_objects(id) ON DELETE CASCADE;


--
-- Name: content_blocks content_blocks_object_volume_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_blocks
    ADD CONSTRAINT content_blocks_object_volume_fkey FOREIGN KEY (object_id, volume_id) REFERENCES pgos_private.content_objects(id, volume_id) ON DELETE CASCADE;


--
-- Name: content_objects content_objects_segment_id_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_objects
    ADD CONSTRAINT content_objects_segment_id_fkey FOREIGN KEY (segment_id) REFERENCES pgos_private.content_segments(id) ON DELETE CASCADE;


--
-- Name: content_objects content_objects_volume_id_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_objects
    ADD CONSTRAINT content_objects_volume_id_fkey FOREIGN KEY (volume_id) REFERENCES pgos_private.volumes(id) ON DELETE CASCADE;


--
-- Name: content_segments content_segments_volume_id_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.content_segments
    ADD CONSTRAINT content_segments_volume_id_fkey FOREIGN KEY (volume_id) REFERENCES pgos_private.volumes(id) ON DELETE CASCADE;


--
-- Name: zone_entries zone_entries_content_object_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE pgos_private.zone_entries
    ADD CONSTRAINT zone_entries_content_object_fkey FOREIGN KEY (content_object) REFERENCES pgos_private.content_objects(id);


--
-- Name: zones zones_volume_id_fkey; Type: FK CONSTRAINT; Schema: pgos_private; Owner: -
--

ALTER TABLE ONLY pgos_private.zones
    ADD CONSTRAINT zones_volume_id_fkey FOREIGN KEY (volume_id) REFERENCES pgos_private.volumes(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--
