//! A tiny JSON reader and writer, enough for the drawer's index file. It exists so the core crate
//! has no dependencies. The index is small and written by this program, but it can be edited by
//! hand, so the parser is strict and returns an error instead of panicking.

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    /// Keys keep their order.
    Obj(Vec<(String, Json)>),
}

const MAX_DEPTH: usize = 64;

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    pub fn as_object(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Obj(items) => Some(items),
            _ => None,
        }
    }

    pub fn to_string_pretty(&self) -> String {
        let mut out = String::new();
        write_value(self, 0, &mut out);
        out.push('\n');
        out
    }

    pub fn parse(text: &str) -> Result<Json, String> {
        let mut p = Parser {
            chars: text.chars().collect(),
            pos: 0,
        };
        p.skip_ws();
        let v = p.value(0)?;
        p.skip_ws();
        if p.pos != p.chars.len() {
            return Err(format!("unexpected trailing text at {}", p.pos));
        }
        Ok(v)
    }
}

fn write_value(v: &Json, indent: usize, out: &mut String) {
    match v {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Num(n) => {
            if !n.is_finite() {
                out.push_str("null");
            } else if n.fract() == 0.0 && n.abs() < 1e15 {
                out.push_str(&format!("{}", *n as i64));
            } else {
                out.push_str(&format!("{n}"));
            }
        }
        Json::Str(s) => write_string(s, out),
        Json::Arr(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                pad(indent + 1, out);
                write_value(item, indent + 1, out);
                out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
            }
            pad(indent, out);
            out.push(']');
        }
        Json::Obj(items) => {
            if items.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push_str("{\n");
            for (i, (k, item)) in items.iter().enumerate() {
                pad(indent + 1, out);
                write_string(k, out);
                out.push_str(": ");
                write_value(item, indent + 1, out);
                out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
            }
            pad(indent, out);
            out.push('}');
        }
    }
}

fn pad(level: usize, out: &mut String) {
    for _ in 0..level {
        out.push_str("  ");
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\n' | '\r')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, c: char) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!("expected '{c}' at {}", self.pos))
        }
    }

    fn literal(&mut self, word: &str, v: Json) -> Result<Json, String> {
        for c in word.chars() {
            self.expect(c)?;
        }
        Ok(v)
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err("nested too deeply".into());
        }
        match self.peek() {
            Some('{') => self.object(depth),
            Some('[') => self.array(depth),
            Some('"') => Ok(Json::Str(self.string()?)),
            Some('t') => self.literal("true", Json::Bool(true)),
            Some('f') => self.literal("false", Json::Bool(false)),
            Some('n') => self.literal("null", Json::Null),
            Some(c) if c == '-' || c.is_ascii_digit() => self.number(),
            Some(c) => Err(format!("unexpected '{c}' at {}", self.pos)),
            None => Err("unexpected end".into()),
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_digit() || matches!(c, '-' | '+' | '.' | 'e' | 'E'))
        {
            self.pos += 1;
        }
        let text: String = self.chars[start..self.pos].iter().collect();
        text.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| format!("bad number '{text}'"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let mut v = 0u32;
        for _ in 0..4 {
            let c = self.peek().ok_or("unexpected end in \\u escape")?;
            v = v * 16
                + c.to_digit(16)
                    .ok_or_else(|| format!("bad hex digit '{c}'"))?;
            self.pos += 1;
        }
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            let c = self.peek().ok_or("unterminated string")?;
            self.pos += 1;
            match c {
                '"' => return Ok(out),
                '\\' => {
                    let e = self.peek().ok_or("unterminated escape")?;
                    self.pos += 1;
                    match e {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{8}'),
                        'f' => out.push('\u{c}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let hi = self.hex4()?;
                            let code = if (0xD800..0xDC00).contains(&hi) {
                                // A high surrogate must be followed by \uXXXX with a low surrogate.
                                self.expect('\\')?;
                                self.expect('u')?;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err("bad surrogate pair".into());
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                hi
                            };
                            out.push(char::from_u32(code).ok_or("bad unicode escape")?);
                        }
                        other => return Err(format!("bad escape '\\{other}'")),
                    }
                }
                c if (c as u32) < 0x20 => return Err("raw control character in string".into()),
                c => out.push(c),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(']') {
            self.pos += 1;
            return Ok(Json::Arr(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.peek() {
                Some(',') => self.pos += 1,
                Some(']') => {
                    self.pos += 1;
                    return Ok(Json::Arr(items));
                }
                _ => return Err(format!("expected ',' or ']' at {}", self.pos)),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.expect('{')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some('}') {
            self.pos += 1;
            return Ok(Json::Obj(items));
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.skip_ws();
            self.expect(':')?;
            self.skip_ws();
            items.push((key, self.value(depth + 1)?));
            self.skip_ws();
            match self.peek() {
                Some(',') => self.pos += 1,
                Some('}') => {
                    self.pos += 1;
                    return Ok(Json::Obj(items));
                }
                _ => return Err(format!("expected ',' or '}}' at {}", self.pos)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_nested_value() {
        let v = Json::Obj(vec![
            (
                "name".into(),
                Json::Str("a \"quoted\" C:\\Users\\me\\x.txt\n".into()),
            ),
            ("n".into(), Json::Num(12.0)),
            ("f".into(), Json::Num(-3.5)),
            (
                "list".into(),
                Json::Arr(vec![Json::Null, Json::Bool(true), Json::Obj(vec![])]),
            ),
            ("empty".into(), Json::Arr(vec![])),
        ]);
        let text = v.to_string_pretty();
        assert_eq!(Json::parse(&text).unwrap(), v);
    }

    #[test]
    fn unicode_names_survive() {
        let v = Json::Str("résumé 日本語 🎉.pdf".into());
        assert_eq!(Json::parse(&v.to_string_pretty()).unwrap(), v);
    }

    #[test]
    fn parses_unicode_escapes_and_surrogates() {
        assert_eq!(Json::parse(r#""\u00e9""#).unwrap(), Json::Str("é".into()));
        assert_eq!(
            Json::parse(r#""\ud83c\udf89""#).unwrap(),
            Json::Str("🎉".into())
        );
        assert!(Json::parse(r#""\ud83c""#).is_err(), "lone high surrogate");
        assert!(Json::parse(r#""\ud83cx""#).is_err());
    }

    #[test]
    fn control_characters_are_escaped_on_output() {
        let text = Json::Str("a\u{1}b".into()).to_string_pretty();
        assert!(text.contains("\\u0001"));
        assert_eq!(Json::parse(&text).unwrap(), Json::Str("a\u{1}b".into()));
    }

    #[test]
    fn numbers() {
        assert_eq!(Json::parse("1e3").unwrap(), Json::Num(1000.0));
        assert_eq!(Json::parse("-0.25").unwrap(), Json::Num(-0.25));
        assert_eq!(
            Json::Num(1_700_000_000.5).to_string_pretty().trim(),
            "1700000000.5"
        );
        assert_eq!(Json::Num(f64::NAN).to_string_pretty().trim(), "null");
        assert!(Json::parse("1.2.3").is_err());
    }

    #[test]
    fn rejects_malformed_input_without_panicking() {
        for bad in [
            "",
            "{",
            "[1,",
            "{\"a\" 1}",
            "{\"a\":}",
            "tru",
            "\"abc",
            "[1] 2",
            "{'a':1}",
            "\"\\q\"",
            "nul",
        ] {
            assert!(Json::parse(bad).is_err(), "{bad:?} should fail");
        }
        let deep = "[".repeat(200);
        assert!(Json::parse(&deep).is_err());
    }

    #[test]
    fn accessors() {
        let v = Json::parse(r#"{"a": "x", "b": 2}"#).unwrap();
        assert_eq!(v.get("a").and_then(Json::as_str), Some("x"));
        assert_eq!(v.get("b").and_then(Json::as_f64), Some(2.0));
        assert!(v.get("c").is_none());
        assert_eq!(v.as_object().unwrap().len(), 2);
    }
}
