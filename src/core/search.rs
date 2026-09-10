//! Exact content matching shared by native tools and the local daemon.

use grep_regex::RegexMatcherBuilder;
use grep_searcher::{SearcherBuilder, sinks::UTF8};
use memchr::memmem::Finder;
use regex_syntax::hir::literal::{ExtractKind, Extractor};

/// Recognize suffix includes that SQL can apply without changing glob semantics.
#[must_use]
pub fn include_suffixes(patterns: &[String]) -> Option<Vec<String>> {
    patterns
        .iter()
        .map(|pattern| {
            let suffix = pattern.strip_prefix('*')?;
            (suffix.starts_with('.')
                && suffix.len() > 1
                && suffix[1..].bytes().all(|byte| byte.is_ascii_alphanumeric()))
            .then(|| suffix.to_owned())
        })
        .collect()
}

/// Translate the proven GNU grep subset, or defer to the installed GNU tool.
/// Basic regex punctuation such as `+` is literal unless escaped in GNU grep.
#[must_use]
pub fn gnu_pattern(pattern: &str, fixed: bool, extended: bool, word: bool) -> Option<String> {
    if pattern.contains('\n') {
        return None;
    }
    let translated = if fixed || !extended {
        if !fixed && pattern.contains(['\\', '.', '[', '*', '^', '$']) {
            return None;
        }
        regex::escape(pattern)
    } else {
        // GNU extensions, locale-sensitive classes and Rust-only syntax must
        // not silently change meaning when passed to the Rust regex engine.
        if !pattern.is_ascii() || pattern.contains('\\') || pattern.contains("(?") {
            return None;
        }
        let hir = regex_syntax::parse(pattern).ok()?;
        if !ascii_word_expression(&hir) {
            return None;
        }
        pattern.to_owned()
    };
    if word {
        let hir = regex_syntax::parse(&translated).ok()?;
        if !ascii_word_expression(&hir) || hir.properties().minimum_len() == Some(0) {
            return None;
        }
        Some(word_pattern(&translated, false))
    } else {
        Some(translated)
    }
}

fn ascii_word_expression(hir: &regex_syntax::hir::Hir) -> bool {
    use regex_syntax::hir::{Class, HirKind};
    let word = |byte: u8| byte.is_ascii_alphanumeric() || byte == b'_';
    match hir.kind() {
        HirKind::Empty | HirKind::Look(_) => true,
        HirKind::Literal(literal) => literal.0.iter().copied().all(word),
        HirKind::Class(Class::Unicode(class)) => class.iter().all(|range| {
            range.start().is_ascii()
                && range.end().is_ascii()
                && (range.start() as u8..=range.end() as u8).all(word)
        }),
        HirKind::Class(Class::Bytes(class)) => class
            .iter()
            .all(|range| (range.start()..=range.end()).all(word)),
        HirKind::Repetition(repetition) => ascii_word_expression(&repetition.sub),
        HirKind::Capture(capture) => ascii_word_expression(&capture.sub),
        HirKind::Concat(parts) | HirKind::Alternation(parts) => {
            parts.iter().all(ascii_word_expression)
        }
    }
}

/// A whole-word ASCII expression can also filter complete identifier tokens.
/// This is a candidate predicate only; the original expression still verifies
/// the file. Do not translate general Rust or GNU regex syntax to `PostgreSQL`.
#[must_use]
pub fn identifier_predicate(pattern: &str) -> Option<String> {
    let inner = pattern.strip_prefix(r"\b(?:")?.strip_suffix(r")\b")?;
    gnu_pattern(inner, false, true, true)?;
    Some(format!("^({inner})$"))
}

/// Format fixed-string matches with standard recursive grep path prefixes.
#[must_use]
pub fn literal_output<'a>(
    files: impl IntoIterator<Item = (&'a str, &'a str)>,
    pattern: &str,
    line_number: bool,
    path_prefix: &str,
) -> (Vec<u8>, bool) {
    let finder = Finder::new(pattern.as_bytes());
    let mut output = Vec::new();
    let mut matched_any = false;

    for (path, text) in files {
        for (index, line) in text
            .as_bytes()
            .split_inclusive(|byte| *byte == b'\n')
            .enumerate()
        {
            let line = line.strip_suffix(b"\n").unwrap_or(line);
            if finder.find(line).is_none() {
                continue;
            }
            matched_any = true;
            output.extend_from_slice(path_prefix.as_bytes());
            output.extend_from_slice(path.as_bytes());
            output.push(b':');
            if line_number {
                output.extend_from_slice((index + 1).to_string().as_bytes());
                output.push(b':');
            }
            output.extend_from_slice(line);
            output.push(b'\n');
        }
    }

    (output, matched_any)
}

/// Return literal alternatives that cover every possible regex match.
#[must_use]
pub fn required_literals(pattern: &str) -> Option<Vec<String>> {
    let hir = regex_syntax::parse(pattern).ok()?;
    let interior = required_interior(&hir);
    [ExtractKind::Prefix, ExtractKind::Suffix]
        .into_iter()
        .filter_map(|kind| {
            let mut extractor = Extractor::new();
            let sequence = extractor.kind(kind).extract(&hir);
            let literals = sequence.literals()?;
            let mut strings = literals
                .iter()
                .map(|literal| std::str::from_utf8(literal.as_bytes()).map(str::to_owned))
                .collect::<Result<Vec<_>, _>>()
                .ok()?;
            if strings.is_empty() || strings.iter().any(|literal| literal.len() < 3) {
                return None;
            }
            strings.sort_unstable();
            strings.dedup();
            Some(strings)
        })
        .chain(interior)
        .min_by_key(|literals| {
            (
                literals.len(),
                std::cmp::Reverse(literals.iter().map(String::len).min().unwrap_or(0)),
            )
        })
}

fn required_interior(hir: &regex_syntax::hir::Hir) -> Option<Vec<String>> {
    use regex_syntax::hir::HirKind;
    match hir.kind() {
        HirKind::Literal(literal) if literal.0.len() >= 3 => {
            Some(vec![std::str::from_utf8(&literal.0).ok()?.to_owned()])
        }
        HirKind::Capture(capture) => required_interior(&capture.sub),
        HirKind::Repetition(repetition) if repetition.min > 0 => required_interior(&repetition.sub),
        HirKind::Concat(parts) => parts
            .iter()
            .filter_map(required_interior)
            .max_by_key(|values| values.iter().map(String::len).min().unwrap_or(0)),
        HirKind::Alternation(parts) => {
            let mut values = Vec::new();
            for part in parts {
                values.extend(required_interior(part)?);
            }
            values.sort_unstable();
            values.dedup();
            Some(values)
        }
        _ => None,
    }
}

/// Candidate extraction only. Replace GNU character escapes with a superset,
/// never with a different definition of a word. GNU grep verifies the result.
#[must_use]
pub fn gnu_required_literals(pattern: &str, fixed: bool, extended: bool) -> Option<Vec<String>> {
    if pattern.contains('\n') {
        return None;
    }
    if fixed {
        return required_literals(&regex::escape(pattern));
    }
    if !extended {
        return required_literals(&gnu_pattern(pattern, false, false, false)?);
    }
    if !pattern.is_ascii()
        || pattern.contains("(?")
        || pattern.contains("[[")
        || pattern.contains('\n')
    {
        return None;
    }
    let mut superset = String::new();
    let mut chars = pattern.chars();
    let mut in_class = false;
    while let Some(character) = chars.next() {
        if character == '[' {
            in_class = true;
        }
        if character == ']' {
            in_class = false;
        }
        if character != '\\' {
            superset.push(character);
            continue;
        }
        if in_class {
            return None;
        }
        match chars.next()? {
            'w' | 'W' | 's' | 'S' => superset.push_str("(?s:.)"),
            _ => return None,
        }
    }
    required_literals(&superset)
}

/// Apply grep-compatible whole-word matching to a pattern.
#[must_use]
pub fn word_pattern(pattern: &str, fixed: bool) -> String {
    let pattern = if fixed {
        regex::escape(pattern)
    } else {
        pattern.to_owned()
    };
    format!(r"\b(?:{pattern})\b")
}

/// `PostgreSQL` ARE expression that extracts complete candidate lines. Literal
/// escaping is shared by these regex syntaxes; arbitrary GNU regex is not.
#[must_use]
pub fn sql_literal_lines_pattern(literals: &[String]) -> String {
    let alternatives = literals
        .iter()
        .map(|value| regex::escape(value))
        .collect::<Vec<_>>()
        .join("|");
    format!("(?n)^.*(?:{alternatives}).*$")
}

/// Extract a complete ASCII word with boundaries established by a mandatory
/// literal or the whole-word constraint. An OR requires separate predicates.
#[must_use]
pub fn required_word(pattern: &str, literals: &[String], whole_word: bool) -> Option<String> {
    if literals.len() != 1 {
        return None;
    }
    let literal = &literals[0];
    let bytes = literal.as_bytes();
    let mut best = None;
    let mut start = 0;
    while start < bytes.len() {
        if !bytes[start].is_ascii_alphanumeric() {
            start += 1;
            continue;
        }
        let mut end = start + 1;
        while end < bytes.len() && bytes[end].is_ascii_alphanumeric() {
            end += 1;
        }
        let left = start > 0 || (whole_word && pattern.starts_with(literal));
        let right = end < bytes.len() || (whole_word && pattern.ends_with(literal));
        if left
            && right
            && (3..=128).contains(&(end - start))
            && best
                .as_ref()
                .is_none_or(|old: &String| old.len() < end - start)
        {
            best = Some(literal[start..end].to_owned());
        }
        start = end;
    }
    best
}

/// Return the minimum contiguous ASCII-letter run guaranteed by every match.
/// This predicate only narrows candidate blocks; GNU grep verifies the match.
#[must_use]
pub fn minimum_ascii_letter_run(pattern: &str, fixed: bool, extended: bool) -> Option<u32> {
    if fixed || !extended || !pattern.is_ascii() {
        return None;
    }
    let hir = regex_syntax::parse(pattern).ok()?;
    let length = guaranteed_ascii_letter_run(&hir)?;
    (length >= 8).then_some(length)
}

fn guaranteed_ascii_letter_run(hir: &regex_syntax::hir::Hir) -> Option<u32> {
    use regex_syntax::hir::{Class, HirKind};
    match hir.kind() {
        HirKind::Literal(literal) => literal
            .0
            .iter()
            .all(u8::is_ascii_alphabetic)
            .then(|| u32::try_from(literal.0.len()).ok())
            .flatten(),
        HirKind::Class(Class::Unicode(class)) => class
            .iter()
            .all(|range| range.start().is_ascii_alphabetic() && range.end().is_ascii_alphabetic())
            .then_some(1),
        HirKind::Class(Class::Bytes(class)) => class
            .iter()
            .all(|range| range.start().is_ascii_alphabetic() && range.end().is_ascii_alphabetic())
            .then_some(1),
        HirKind::Capture(capture) => guaranteed_ascii_letter_run(&capture.sub),
        HirKind::Repetition(repetition) => {
            guaranteed_ascii_letter_run(&repetition.sub)?.checked_mul(repetition.min)
        }
        HirKind::Concat(parts) => parts.iter().filter_map(guaranteed_ascii_letter_run).max(),
        HirKind::Alternation(parts) => parts
            .iter()
            .map(guaranteed_ascii_letter_run)
            .collect::<Option<Vec<_>>>()?
            .into_iter()
            .min(),
        HirKind::Empty | HirKind::Look(_) => None,
    }
}

/// Verify regex matches and format standard recursive grep output.
pub fn regex_output<'a>(
    files: impl IntoIterator<Item = (&'a str, &'a str)>,
    pattern: &str,
    line_number: bool,
    path_prefix: &str,
) -> Result<(Vec<u8>, bool), SearchError> {
    // Use ripgrep's matcher and searcher so literal skipping and line handling
    // remain upstream responsibilities, instead of matching every line here.
    let matcher = RegexMatcherBuilder::new()
        .multi_line(true)
        .line_terminator(Some(b'\n'))
        .build(pattern)?;
    // GNU grep preserves a UTF-8 BOM as file content; ripgrep's searcher
    // otherwise strips it before matching and printing.
    let mut searcher = SearcherBuilder::new().bom_sniffing(false).build();
    let mut output = Vec::new();
    let mut matched_any = false;

    for (path, text) in files {
        searcher.search_slice(
            &matcher,
            text.as_bytes(),
            UTF8(|number, line| {
                matched_any = true;
                output.extend_from_slice(path_prefix.as_bytes());
                output.extend_from_slice(path.as_bytes());
                output.push(b':');
                if line_number {
                    output.extend_from_slice(number.to_string().as_bytes());
                    output.push(b':');
                }
                output.extend_from_slice(line.as_bytes());
                if !line.ends_with('\n') {
                    output.push(b'\n');
                }
                Ok(true)
            }),
        )?;
    }

    Ok((output, matched_any))
}

#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error(transparent)]
    Pattern(#[from] grep_regex::Error),
    #[error(transparent)]
    Search(#[from] std::io::Error),
}

/// A reusable matcher for line-aligned blocks of one file. Line numbers are
/// relative to the complete file, not to each database row.
pub struct BlockMatcher {
    matcher: grep_regex::RegexMatcher,
    searcher: grep_searcher::Searcher,
    line_number: bool,
}

impl BlockMatcher {
    #[must_use]
    pub fn worker(&self) -> Self {
        Self {
            matcher: self.matcher.clone(),
            searcher: SearcherBuilder::new()
                .bom_sniffing(false)
                .line_number(self.line_number)
                .build(),
            line_number: self.line_number,
        }
    }

    pub fn literals(literals: &[String]) -> Result<Self, SearchError> {
        let pattern = literals
            .iter()
            .map(|literal| regex::escape(literal))
            .collect::<Vec<_>>()
            .join("|");
        Self::new(&pattern, false)
    }

    pub fn new(pattern: &str, line_number: bool) -> Result<Self, SearchError> {
        Ok(Self {
            matcher: RegexMatcherBuilder::new()
                .multi_line(true)
                .line_terminator(Some(b'\n'))
                .build(pattern)?,
            searcher: SearcherBuilder::new()
                .bom_sniffing(false)
                .line_number(line_number)
                .build(),
            line_number,
        })
    }

    pub fn search(&mut self, first_line: i64, text: &str) -> Result<(Vec<u8>, bool), SearchError> {
        self.search_prefixed(first_line, text, &[])
    }

    pub fn search_prefixed(
        &mut self,
        first_line: i64,
        text: &str,
        prefix: &[u8],
    ) -> Result<(Vec<u8>, bool), SearchError> {
        let mut sink = BlockOutput {
            output: Vec::new(),
            first_line,
            line_number: self.line_number,
            found: false,
            prefix,
        };
        self.searcher
            .search_slice(&self.matcher, text.as_bytes(), &mut sink)?;
        Ok((sink.output, sink.found))
    }
}

struct BlockOutput<'a> {
    output: Vec<u8>,
    first_line: i64,
    line_number: bool,
    found: bool,
    prefix: &'a [u8],
}

impl grep_searcher::Sink for BlockOutput<'_> {
    type Error = std::io::Error;

    fn matched(
        &mut self,
        _: &grep_searcher::Searcher,
        hit: &grep_searcher::SinkMatch<'_>,
    ) -> Result<bool, Self::Error> {
        self.found = true;
        self.output.extend_from_slice(self.prefix);
        if self.line_number {
            let number =
                u64::try_from(self.first_line).unwrap_or(1) + hit.line_number().unwrap_or(1) - 1;
            self.output.extend_from_slice(number.to_string().as_bytes());
            self.output.push(b':');
        }
        // Diesel already checked UTF-8 when it decoded the text column. Do
        // not validate each matching line again or count unrequested numbers.
        self.output.extend_from_slice(hit.bytes());
        if !hit.bytes().ends_with(b"\n") {
            self.output.push(b'\n');
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::{gnu_pattern, literal_output, regex_output, required_literals, word_pattern};

    #[test]
    fn extracts_mandatory_interior_without_changing_gnu_word_semantics() {
        assert_eq!(
            super::gnu_required_literals(r"[A-Z]\w+ Sherlock [A-Z]\w+", false, true),
            Some(vec![" Sherlock ".into()])
        );
        assert_eq!(super::gnu_required_literals("abc\ndef", true, false), None);
        assert_eq!(super::gnu_required_literals(r"[a\w]abc", false, true), None);
        assert_eq!(required_literals("(Sherlock)?[A-Z]+"), None);
    }

    #[test]
    fn word_index_requires_proven_boundaries() {
        assert_eq!(
            super::required_word("Sherlock .*", &["Sherlock ".into()], true),
            Some("Sherlock".into())
        );
        assert_eq!(
            super::required_word("Sherlock .*", &["Sherlock ".into()], false),
            None
        );
        assert_eq!(
            super::required_word("x+Sherlock .*", &["Sherlock ".into()], true),
            None
        );
        assert_eq!(
            super::required_word(".* Sherlock .*", &[" Sherlock ".into()], false),
            Some("Sherlock".into())
        );
        assert_eq!(
            super::required_word("abc|def", &["abc".into(), "def".into()], true),
            None
        );
    }

    #[test]
    fn extracts_only_guaranteed_long_ascii_runs() {
        assert_eq!(
            super::minimum_ascii_letter_run("[A-Za-z]{30}", false, true),
            Some(30)
        );
        assert_eq!(
            super::minimum_ascii_letter_run("[A-Za-z]{7}", false, true),
            None
        );
        assert_eq!(
            super::minimum_ascii_letter_run("([A-Za-z]{12}|[0-9]+)", false, true),
            None
        );
        assert_eq!(
            super::minimum_ascii_letter_run("literal", false, false),
            None
        );
    }

    #[test]
    fn gnu_basic_regex_does_not_treat_plus_as_repetition() {
        assert_eq!(
            gnu_pattern("a+b", false, false, false),
            Some(r"a\+b".into())
        );
        assert_eq!(gnu_pattern("a+b", false, true, false), Some("a+b".into()));
        assert_eq!(gnu_pattern(r"\(a\)\1", false, false, false), None);
        assert_eq!(gnu_pattern(r"(?i)abc", false, true, false), None);
        assert_eq!(gnu_pattern("a+b", true, false, true), None);
    }

    #[test]
    fn matching_preserves_carriage_returns_and_unterminated_lines() {
        let files = [("/a", "match\r\nmatch")];
        let expected = b"/a:1:match\r\n/a:2:match\n";
        assert_eq!(literal_output(files, "match", true, "").0, expected);
        assert_eq!(regex_output(files, "match", true, "").unwrap().0, expected);
    }

    #[test]
    fn preserves_grep_line_output() {
        let (output, matched) = literal_output(
            [("/docs/example.txt", "first\r\nmatch here\nlast match")],
            "match",
            true,
            "",
        );

        assert!(matched);
        assert_eq!(
            output,
            b"/docs/example.txt:2:match here\n/docs/example.txt:3:last match\n"
        );
    }

    #[test]
    fn returns_false_without_output_for_no_match() {
        let (output, matched) = literal_output(
            [("/docs/example.txt", "first\nsecond\n")],
            "absent",
            false,
            "",
        );

        assert!(!matched);
        assert!(output.is_empty());
    }

    #[test]
    fn extracts_one_required_regex_literal() {
        assert_eq!(
            required_literals(r"\b[A-Z]+_SUSPEND\b"),
            Some(vec!["_SUSPEND".to_owned()])
        );
        assert_eq!(
            required_literals(r"ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"),
            Some(vec![
                "CFG_BME_EVT".to_owned(),
                "ERR_SYS".to_owned(),
                "LINK_REQ_RST".to_owned(),
                "PME_TURN_OFF".to_owned(),
            ])
        );
        assert_eq!(required_literals(r"\w{5}\s+\w{5}"), None);
    }

    #[test]
    fn verifies_complete_regex_after_literal_filtering() {
        let (output, matched) = regex_output(
            [
                ("/a.c", "PM_SUSPEND\nnot-lower_SUSPEND\n"),
                ("/b.c", "NO_MATCH\n"),
            ],
            r"\b[A-Z]+_SUSPEND\b",
            true,
            "",
        )
        .unwrap();

        assert!(matched);
        assert_eq!(output, b"/a.c:1:PM_SUSPEND\n");
    }

    #[test]
    fn whole_word_fixed_pattern_escapes_regex_syntax() {
        assert_eq!(word_pattern("a+b", true), r"\b(?:a\+b)\b");
    }
}
