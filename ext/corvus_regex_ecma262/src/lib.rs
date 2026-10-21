//! The native extension of the corvus_regex_ecma262 gem: the corvus-regex-ecma262 crate over Ruby strings. The Ruby
//! library (lib/corvus_regex_ecma262.rb) is the API; this is the part that matches.
//!
//! A string is matched as it is held: a UTF-8 (or US-ASCII, or ASCII-only binary) string as UTF-8, positions in bytes,
//! and a UTF-16LE string as UTF-16, positions in code units. A match's groups come back as one flat Array of integers:
//! the start and the end of each group (the whole match first), then of the group of each name, -1 for a group that
//! did not take part. The Ruby library turns them into a Match.

use std::time::Duration;

use corvus_regex_ecma262 as ecma;
use magnus::encoding::Coderange;
use magnus::encoding::EncodingCapable;
use magnus::prelude::*;
use magnus::rb_sys::AsRawValue;
use magnus::{Error, ExceptionClass, RArray, RModule, RString, Ruby, Value, function, method};

fn error_class(ruby: &Ruby, name: &str) -> ExceptionClass {
    let module: RModule = ruby.class_object().const_get("CorvusRegexEcma262").expect("the module is defined");
    module.const_get(name).expect("the error classes are defined")
}

fn compile_error(ruby: &Ruby, e: ecma::Error) -> Error {
    let class = match e {
        ecma::Error::TooLarge(_) => "PatternTooLargeError",
        ecma::Error::Flags(_) => "InvalidFlagsError",
        _ => "InvalidPatternError",
    };
    Error::new(error_class(ruby, class), e.to_string())
}

fn limit_error(ruby: &Ruby, e: ecma::MatchError) -> Error {
    Error::new(error_class(ruby, "MatchLimitError"), e.to_string())
}

/// The text of a call: UTF-8 borrowed from the string, or its UTF-16LE read in place where its bytes are aligned for
/// u16 (as a string's own buffer is) and copied into units where they are not.
enum Text<'a> {
    Utf8(&'a str),
    Utf16(std::borrow::Cow<'a, [u16]>),
}

#[derive(Clone, Copy)]
enum View<'a> {
    Utf8(&'a str),
    Utf16(&'a [u16]),
}

impl Text<'_> {
    fn view(&self) -> View<'_> {
        match self {
            Text::Utf8(s) => View::Utf8(s),
            Text::Utf16(u) => View::Utf16(u),
        }
    }
}

/// The text of a string, as its encoding says it is held. SAFETY: the caller must not let Ruby code run, nor the
/// string change, while the text is borrowed (a call that yields locks the string first).
unsafe fn text_of<'a>(ruby: &Ruby, s: RString) -> Result<Text<'a>, Error> {
    let enc = s.enc_get();
    // SAFETY: the bytes stay as they are for the call, as the caller ensures.
    let bytes: &'a [u8] = unsafe { std::mem::transmute::<&[u8], &'a [u8]>(s.as_slice()) };
    if enc == ruby.find_encindex("UTF-16LE")? {
        // SAFETY: any two bytes are a u16; align_to gives the aligned middle, which is all of it when the start is
        // aligned and the length even. The targets the gem is built for are little-endian, as UTF-16LE is.
        let (head, units, tail) = unsafe { bytes.align_to::<u16>() };
        if cfg!(target_endian = "little") && head.is_empty() && tail.is_empty() {
            return Ok(Text::Utf16(std::borrow::Cow::Borrowed(units)));
        }
        return Ok(Text::Utf16(std::borrow::Cow::Owned(
            bytes.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect(),
        )));
    }
    let utf8 = enc == ruby.utf8_encindex() || enc == ruby.usascii_encindex();
    // Ruby keeps what it has read of a string's bytes (its coderange), so this reads them once for the string's life.
    match s.enc_coderange_scan() {
        Coderange::SevenBit => {}
        Coderange::Valid if utf8 => {}
        _ if !utf8 && enc != ruby.ascii8bit_encindex() => {
            return Err(Error::new(
                ruby.exception_encoding_error(),
                "the string must be UTF-8 (or US-ASCII, or binary holding UTF-8) or UTF-16LE",
            ));
        }
        _ => {
            if std::str::from_utf8(bytes).is_err() {
                return Err(Error::new(ruby.exception_arg_error(), "invalid byte sequence in UTF-8"));
            }
        }
    }
    // SAFETY: checked above (seven-bit, valid UTF-8, or read as UTF-8 just now).
    Ok(Text::Utf8(unsafe { std::str::from_utf8_unchecked(bytes) }))
}

fn limit_of(timeout: Option<f64>) -> Option<Duration> {
    timeout.map(|t| Duration::from_secs_f64(t.max(0.0)))
}

#[magnus::wrap(class = "CorvusRegexEcma262::Native::Regex", free_immediately, size)]
struct NativeRegex {
    inner: ecma::Regex,
    /// Neither u nor v: a match is by UTF-16 code unit.
    legacy: bool,
    global: bool,
    names: Vec<String>,
}

impl NativeRegex {
    /// The groups of a match as the flat Array the Ruby library reads.
    fn flat<H: ?Sized + ecma::Haystack>(&self, ruby: &Ruby, caps: &ecma::Captures<'_, H>) -> RArray {
        let out = ruby.ary_new_capa(2 * (caps.len() + self.names.len()));
        let push = |m: Option<(usize, usize)>| {
            let (s, e) = m.map_or((-1, -1), |(s, e)| (s as i64, e as i64));
            let _ = out.push(s);
            let _ = out.push(e);
        };
        for m in caps.iter() {
            push(m.map(|m| (m.start(), m.end())));
        }
        for name in &self.names {
            push(caps.name(name).map(|m| (m.start(), m.end())));
        }
        out
    }

    fn captures_at(
        &self,
        ruby: &Ruby,
        view: View<'_>,
        start: usize,
        limit: Option<Duration>,
    ) -> Result<Option<RArray>, Error> {
        Ok(match view {
            View::Utf8(s) => {
                let caps = match limit {
                    Some(l) => self.inner.try_captures_at(s, start, l).map_err(|e| limit_error(ruby, e))?,
                    None => self.inner.captures_at(s, start),
                };
                caps.map(|c| self.flat(ruby, &c))
            }
            View::Utf16(u) => {
                let caps = match limit {
                    Some(l) => self.inner.try_captures_at_utf16(u, start, l).map_err(|e| limit_error(ruby, e))?,
                    None => self.inner.captures_at_utf16(u, start),
                };
                caps.map(|c| self.flat(ruby, &c))
            }
        })
    }

    /// The position after an empty match at `at`: one code point on with u or v, one code unit without (over UTF-8,
    /// from a character beyond the Basic Multilingual Plane that is its third byte, between its halves).
    fn advance(&self, view: View<'_>, at: usize) -> usize {
        match view {
            View::Utf8(s) => {
                let b = s.as_bytes();
                if self.legacy && at < b.len() && b[at] >= 0xF0 {
                    return at + 2;
                }
                let mut next = at + 1;
                while next < b.len() && (b[next] & 0xC0) == 0x80 {
                    next += 1;
                }
                next
            }
            View::Utf16(u) => {
                if !self.legacy
                    && at + 1 < u.len()
                    && (0xD800..0xDC00).contains(&u[at])
                    && (0xDC00..0xE000).contains(&u[at + 1])
                {
                    at + 2
                } else {
                    at + 1
                }
            }
        }
    }

    fn len(view: View<'_>) -> usize {
        match view {
            View::Utf8(s) => s.len(),
            View::Utf16(u) => u.len(),
        }
    }
}

/// Locks a string against change while Ruby code runs inside a call that has its text borrowed.
struct Locked(Value);

impl Locked {
    fn new(s: RString) -> Locked {
        // SAFETY: rb_str_locktmp raises if the string is already locked, which a nested call does not do here.
        unsafe { rb_sys::rb_str_locktmp(s.as_raw()) };
        Locked(s.as_value())
    }
}

impl Drop for Locked {
    fn drop(&mut self) {
        // SAFETY: the string was locked by new.
        unsafe { rb_sys::rb_str_unlocktmp(self.0.as_raw()) };
    }
}

impl NativeRegex {
    fn new(ruby: &Ruby, pattern: RString, flags: RString) -> Result<NativeRegex, Error> {
        let pattern = pattern.to_string()?;
        let flags = flags.to_string()?;
        let inner = ecma::Regex::new(&pattern, &flags).map_err(|e| compile_error(ruby, e))?;
        let written = format!("{}", inner.flags());
        let names = inner.group_names().map(str::to_owned).collect();
        Ok(NativeRegex {
            legacy: !written.contains('u') && !written.contains('v'),
            global: written.contains('g'),
            inner,
            names,
        })
    }

    fn is_valid(pattern: RString, flags: RString) -> Result<bool, Error> {
        Ok(ecma::Regex::is_valid(&pattern.to_string()?, &flags.to_string()?))
    }

    fn source(&self) -> String {
        self.inner.as_str().to_owned()
    }

    fn flags(&self) -> String {
        format!("{}", self.inner.flags())
    }

    fn group_count(&self) -> usize {
        self.inner.captures_len() - 1
    }

    fn names(&self) -> Vec<String> {
        self.names.clone()
    }

    fn global(&self) -> bool {
        self.global
    }

    /// Whether the pattern matches at or after start (an engine position).
    fn test(ruby: &Ruby, rb_self: &Self, s: RString, start: usize, timeout: Option<f64>) -> Result<bool, Error> {
        // SAFETY: no Ruby code runs while the text is borrowed.
        let text = unsafe { text_of(ruby, s)? };
        let view = text.view();
        if start > NativeRegex::len(view) {
            return Ok(false);
        }
        let inner = &rb_self.inner;
        match (view, limit_of(timeout)) {
            (View::Utf8(t), None) => Ok(inner.is_match_at(t, start)),
            (View::Utf16(u), None) => Ok(inner.is_match_at_utf16(u, start)),
            (View::Utf8(t), Some(l)) => {
                inner.try_find_at(t, start, l).map(|m| m.is_some()).map_err(|e| limit_error(ruby, e))
            }
            (View::Utf16(u), Some(l)) => {
                inner.try_find_at_utf16(u, start, l).map(|m| m.is_some()).map_err(|e| limit_error(ruby, e))
            }
        }
    }

    /// The first match at or after start (an engine position): its flat groups, or nil.
    fn exec(
        ruby: &Ruby,
        rb_self: &Self,
        s: RString,
        start: usize,
        timeout: Option<f64>,
    ) -> Result<Option<RArray>, Error> {
        // SAFETY: no Ruby code runs while the text is borrowed.
        let text = unsafe { text_of(ruby, s)? };
        let view = text.view();
        if start > NativeRegex::len(view) {
            return Ok(None);
        }
        rb_self.captures_at(ruby, view, start, limit_of(timeout))
    }

    /// Every match of a global search, as matchAll makes one, each yielded as its flat groups. Returns the number of
    /// matches.
    fn each(ruby: &Ruby, rb_self: &Self, s: RString) -> Result<usize, Error> {
        let _lock = Locked::new(s);
        // SAFETY: the string is locked against change while the block runs.
        let text = unsafe { text_of(ruby, s)? };
        let view = text.view();
        let len = NativeRegex::len(view);
        let mut at = 0;
        let mut n = 0;
        while at <= len {
            let Some(groups) = rb_self.captures_at(ruby, view, at, None)? else { break };
            let (s, e): (i64, i64) = (groups.entry(0)?, groups.entry(1)?);
            let _: Value = ruby.yield_value(groups)?;
            n += 1;
            at = if e == s { rb_self.advance(view, e as usize) } else { e as usize };
        }
        Ok(n)
    }

    /// The number of matches of a global search, without yielding them.
    fn count(ruby: &Ruby, rb_self: &Self, s: RString) -> Result<usize, Error> {
        // SAFETY: no Ruby code runs while the text is borrowed.
        let text = unsafe { text_of(ruby, s)? };
        Ok(match text.view() {
            View::Utf8(t) => rb_self.inner.find_iter(t).count(),
            View::Utf16(u) => rb_self.inner.find_iter_utf16(u).count(),
        })
    }

    /// The text with the first match replaced, or every match with all, by a template: the bytes, in the text's
    /// encoding.
    fn replace(ruby: &Ruby, rb_self: &Self, s: RString, template: RString, all: bool) -> Result<RString, Error> {
        // SAFETY: no Ruby code runs while the texts are borrowed.
        let text = unsafe { text_of(ruby, s)? };
        let template = unsafe { text_of(ruby, template)? };
        let inner = &rb_self.inner;
        Ok(match (text.view(), template.view()) {
            (View::Utf8(t), View::Utf8(r)) => {
                let out = if all { inner.replace_all(t, r) } else { inner.replace(t, r) };
                ruby.str_from_slice(out.as_bytes())
            }
            (View::Utf16(t), View::Utf16(r)) => {
                let out = if all { inner.replace_all_utf16(t, r) } else { inner.replace_utf16(t, r) };
                let bytes: Vec<u8> = out.iter().flat_map(|u| u.to_le_bytes()).collect();
                ruby.str_from_slice(&bytes)
            }
            _ => return Err(Error::new(ruby.exception_arg_error(), "the replacement's encoding is not the string's")),
        })
    }

    /// The text split around the matches: the pieces' bytes in the text's encoding, nil for a group that did not take
    /// part.
    fn split(ruby: &Ruby, rb_self: &Self, s: RString, limit: Option<usize>) -> Result<RArray, Error> {
        // SAFETY: no Ruby code runs while the text is borrowed.
        let text = unsafe { text_of(ruby, s)? };
        let inner = &rb_self.inner;
        let out = ruby.ary_new();
        match text.view() {
            View::Utf8(t) => {
                let pieces = match limit {
                    Some(n) => inner.splitn(t, n),
                    None => inner.split(t),
                };
                for p in pieces {
                    out.push(p.map(|p| ruby.str_from_slice(p.as_bytes())))?;
                }
            }
            View::Utf16(u) => {
                let pieces = match limit {
                    Some(n) => inner.splitn_utf16(u, n),
                    None => inner.split_utf16(u),
                };
                for p in pieces {
                    out.push(p.map(|p| {
                        let bytes: Vec<u8> = p.iter().flat_map(|u| u.to_le_bytes()).collect();
                        ruby.str_from_slice(&bytes)
                    }))?;
                }
            }
        }
        Ok(out)
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("CorvusRegexEcma262")?;
    let error = module.define_error("Error", ruby.exception_standard_error())?;
    module.define_error("InvalidPatternError", error)?;
    module.define_error("InvalidFlagsError", error)?;
    module.define_error("PatternTooLargeError", error)?;
    module.define_error("MatchLimitError", error)?;
    let native = module.define_module("Native")?;
    native.define_singleton_method("crate_version", function!(|| env!("CARGO_PKG_VERSION"), 0))?;
    let regex = native.define_class("Regex", ruby.class_object())?;
    regex.define_singleton_method("new", function!(NativeRegex::new, 2))?;
    regex.define_singleton_method("valid?", function!(NativeRegex::is_valid, 2))?;
    regex.define_method("source", method!(NativeRegex::source, 0))?;
    regex.define_method("flags", method!(NativeRegex::flags, 0))?;
    regex.define_method("group_count", method!(NativeRegex::group_count, 0))?;
    regex.define_method("names", method!(NativeRegex::names, 0))?;
    regex.define_method("global?", method!(NativeRegex::global, 0))?;
    regex.define_method("test", method!(NativeRegex::test, 3))?;
    regex.define_method("exec", method!(NativeRegex::exec, 3))?;
    regex.define_method("each", method!(NativeRegex::each, 1))?;
    regex.define_method("count", method!(NativeRegex::count, 1))?;
    regex.define_method("replace", method!(NativeRegex::replace, 3))?;
    regex.define_method("split", method!(NativeRegex::split, 2))?;
    Ok(())
}
