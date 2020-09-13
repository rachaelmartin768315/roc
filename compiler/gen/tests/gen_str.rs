#[macro_use]
extern crate pretty_assertions;
#[macro_use]
extern crate indoc;

extern crate bumpalo;
extern crate inkwell;
extern crate libc;
extern crate roc_gen;

#[macro_use]
mod helpers;

#[cfg(test)]
mod gen_str {
    #[test]
    fn str_concat_big_to_big() {
        assert_evals_to!(
            indoc!(
                r#"
                    Str.concat
                        "First string that is fairly long. Longer strings make for different errors. "
                        "Second string that is also fairly long. Two long strings test things that might not appear with short strings."
                "#
            ),
            "First string that is fairly long. Longer strings make for different errors. Second string that is also fairly long. Two long strings test things that might not appear with short strings.",
            &'static str
        );
    }

    #[test]
    fn small_str_literal() {
        assert_evals_to!(
            "\"JJJJJJJJJJJJJJJ\"",
            [
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0b1000_1111
            ],
            [u8; 16]
        );
    }

    #[test]
    fn small_str_concat_empty_first_arg() {
        assert_evals_to!(
            r#"Str.concat "" "JJJJJJJJJJJJJJJ""#,
            [
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0b1000_1111
            ],
            [u8; 16]
        );
    }

    #[test]
    fn small_str_concat_empty_second_arg() {
        assert_evals_to!(
            r#"Str.concat "JJJJJJJJJJJJJJJ" """#,
            [
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0b1000_1111
            ],
            [u8; 16]
        );
    }

    #[test]
    fn small_str_concat_small_to_big() {
        assert_evals_to!(
            r#"Str.concat "abc" " this is longer than 15 chars""#,
            "abc this is longer than 15 chars",
            &'static str
        );
    }

    #[test]
    fn small_str_concat_small_to_small_staying_small() {
        assert_evals_to!(
            r#"Str.concat "J" "JJJJJJJJJJJJJJ""#,
            [
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0x4a,
                0b1000_1111
            ],
            [u8; 16]
        );
    }

    #[test]
    fn small_str_concat_small_to_small_overflow_to_big() {
        assert_evals_to!(
            r#"Str.concat "abcdefghijklm" "nopqrstuvwxyz""#,
            "abcdefghijklmnopqrstuvwxyz",
            &'static str
        );
    }

    #[test]
    fn str_concat_empty() {
        assert_evals_to!(r#"Str.concat "" """#, "", &'static str);
    }

    #[test]
    fn small_str_is_empty() {
        assert_evals_to!(r#"Str.isEmpty "abc""#, false, bool);
    }

    #[test]
    fn big_str_is_empty() {
        assert_evals_to!(
            r#"Str.isEmpty "this is more than 15 chars long""#,
            false,
            bool
        );
    }

    #[test]
    fn empty_str_is_empty() {
        assert_evals_to!(r#"Str.isEmpty """#, true, bool);
    }
}
