//! Text that reaches a public page as written: no control characters, no
//! bidirectional formatting (U+202E would make "fdp.exe" read "exe.pdf"),
//! no line or paragraph separators, nothing that renders as something
//! other than what it holds.

fn unsafe_char(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{061C}' | '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
        || matches!(c, '\u{2028}' | '\u{2029}')
}

/// One line of at most `max` UTF-16 code units, the Dart domain's measure.
pub fn safe_line(text: &str, max: usize) -> bool {
    text.encode_utf16().count() <= max && !text.chars().any(unsafe_char)
}

/// Text with lines (and tabs) of at most `max` UTF-16 code units in all.
pub fn safe_text(text: &str, max: usize) -> bool {
    text.encode_utf16().count() <= max && !text.chars().any(|c| c != '\n' && c != '\t' && unsafe_char(c))
}

/// `text` for HTML text and double-quoted attributes.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_and_text() {
        assert!(safe_line("Ciao mondo", 10));
        assert!(!safe_line("Ciao mondo!", 10));
        assert!(!safe_line("a\nb", 10));
        assert!(!safe_line("a\u{202E}b", 10));
        assert!(!safe_line("a\u{2028}b", 10));
        assert!(safe_text("a\nb\tc", 10));
        assert!(!safe_text("a\rb", 10));
        assert!(!safe_text("a\u{2066}b", 10));
        // Code units, as Dart counts: an emoji is two.
        assert!(safe_line("😀", 2));
        assert!(!safe_line("😀", 1));
    }

    #[test]
    fn escaping() {
        assert_eq!(escape(r#"<a href="x">'&'</a>"#), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    }
}
