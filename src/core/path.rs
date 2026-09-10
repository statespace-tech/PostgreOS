//! Canonical path handling for the SQL and filesystem boundaries.

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PathError {
    #[error("path must be absolute")]
    NotAbsolute,
    #[error("path contains a NUL byte")]
    Nul,
    #[error("path escapes the volume root")]
    EscapesRoot,
}

/// Converts an absolute UTF-8 path to the canonical `PostgreOS` form.
pub fn normalize(path: &str) -> Result<String, PathError> {
    if !path.starts_with('/') {
        return Err(PathError::NotAbsolute);
    }
    if path.as_bytes().contains(&0) {
        return Err(PathError::Nul);
    }

    // Normalize before a path reaches SQL. This gives every node one key and
    // prevents `..` from crossing the volume boundary.
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(PathError::EscapesRoot);
                }
            }
            value => parts.push(value),
        }
    }

    if parts.is_empty() {
        Ok("/".to_owned())
    } else {
        Ok(format!("/{}", parts.join("/")))
    }
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn normalizes_paths() {
        assert_eq!(normalize("/").unwrap(), "/");
        assert_eq!(normalize("/a//b/./c").unwrap(), "/a/b/c");
        assert_eq!(normalize("/a/b/../c").unwrap(), "/a/c");
        assert!(normalize("relative").is_err());
        assert!(normalize("../outside").is_err());
    }
}
