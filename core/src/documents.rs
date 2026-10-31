//! Content validation shared by document hosts.
pub fn valid_content(title: &str, body: &str) -> bool {
    !title.trim().is_empty() && title.len() <= 200 && body.len() <= 100_000
}
#[cfg(test)]
mod tests {
    use super::valid_content;
    #[test]
    fn rejects_empty_title_and_excessive_content() {
        assert!(!valid_content("  ", "x"));
        assert!(valid_content("Notes", ""));
        assert!(!valid_content("Notes", &"x".repeat(100_001)));
    }
}
