#[cfg(feature = "gen-llvm")]
use crate::helpers::llvm::assert_evals_to;

#[cfg(feature = "gen-dev")]
use crate::helpers::dev::assert_evals_to;

#[cfg(feature = "gen-wasm")]
use crate::helpers::wasm::assert_evals_to;

#[cfg(test)]
use indoc::indoc;

#[test]
#[cfg(any(feature = "gen-llvm", feature = "gen-wasm"))]
fn hash_specialization() {
    assert_evals_to!(
        indoc!(
            r#"
            app "test" provides [ main ] to "./platform"

            Hash has
                hash : a -> U64 | a has Hash

            Id := U64

            hash = \$Id n -> n

            main = hash ($Id 1234)
            "#
        ),
        1234,
        u64
    );
}

#[test]
#[cfg(any(feature = "gen-llvm", feature = "gen-wasm"))]
fn hash_specialization_multiple_add() {
    assert_evals_to!(
        indoc!(
            r#"
            app "test" provides [ main ] to "./platform"

            Hash has
                hash : a -> U64 | a has Hash

            Id := U64

            hash = \$Id n -> n

            One := {}

            hash = \$One _ -> 1

            main = hash ($Id 1234) + hash ($One {})
            "#
        ),
        1235,
        u64
    );
}

#[test]
#[cfg(any(feature = "gen-llvm", feature = "gen-wasm"))]
fn alias_member_specialization() {
    assert_evals_to!(
        indoc!(
            r#"
            app "test" provides [ main ] to "./platform"

            Hash has
                hash : a -> U64 | a has Hash

            Id := U64

            hash = \$Id n -> n

            main =
                aliasedHash = hash
                aliasedHash ($Id 1234)
            "#
        ),
        1234,
        u64
    );
}
