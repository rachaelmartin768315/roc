//! Provides types to describe problems that can occur during solving.
use roc_can::expected::{Expected, PExpected};
use roc_module::{ident::Lowercase, symbol::Symbol};
use roc_problem::{can::CycleEntry, Severity};
use roc_region::all::Region;

use roc_types::types::{Category, ErrorType, PatternCategory};

#[derive(Debug, Clone)]
pub enum TypeError {
    BadExpr(Region, Category, ErrorType, Expected<ErrorType>),
    BadPattern(Region, PatternCategory, ErrorType, PExpected<ErrorType>),
    CircularType(Region, Symbol, ErrorType),
    CircularDef(Vec<CycleEntry>),
    UnexposedLookup(Symbol),
    UnfulfilledAbility(Unfulfilled),
    BadExprMissingAbility(Region, Category, ErrorType, Vec<Unfulfilled>),
    BadPatternMissingAbility(Region, PatternCategory, ErrorType, Vec<Unfulfilled>),
    Exhaustive(roc_exhaustive::Error),
    StructuralSpecialization {
        region: Region,
        typ: ErrorType,
        ability: Symbol,
        member: Symbol,
    },
    WrongSpecialization {
        region: Region,
        ability_member: Symbol,
        expected_opaque: Symbol,
        found_opaque: Symbol,
    },
}

impl TypeError {
    pub fn severity(&self) -> Severity {
        use Severity::*;
        match self {
            TypeError::BadExpr(..) => RuntimeError,
            TypeError::BadPattern(..) => RuntimeError,
            TypeError::CircularType(..) => RuntimeError,
            TypeError::CircularDef(_) => RuntimeError,
            TypeError::UnexposedLookup(_) => RuntimeError,
            TypeError::UnfulfilledAbility(_) => RuntimeError,
            TypeError::BadExprMissingAbility(_, _, _, _) => RuntimeError,
            TypeError::BadPatternMissingAbility(_, _, _, _) => RuntimeError,
            // NB: if bidirectional exhaustiveness checking is implemented, the other direction
            // is also not a runtime error.
            TypeError::Exhaustive(exhtv) => exhtv.severity(),
            TypeError::StructuralSpecialization { .. } => RuntimeError,
            TypeError::WrongSpecialization { .. } => RuntimeError,
        }
    }
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum Unfulfilled {
    /// No claimed implementation of an ability for an opaque type.
    OpaqueDoesNotImplement { typ: Symbol, ability: Symbol },
    /// Cannot derive implementation of an ability for a structural type.
    AdhocUnderivable {
        typ: ErrorType,
        ability: Symbol,
        reason: UnderivableReason,
    },
    /// Cannot derive implementation of an ability for an opaque type.
    OpaqueUnderivable {
        typ: ErrorType,
        ability: Symbol,
        opaque: Symbol,
        derive_region: Region,
        reason: UnderivableReason,
    },
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum UnderivableReason {
    NotABuiltin,
    /// The surface type is not derivable
    SurfaceNotDerivable(NotDerivableContext),
    /// A nested type is not derivable
    NestedNotDerivable(ErrorType, NotDerivableContext),
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum NotDerivableContext {
    NoContext,
    Function,
    UnboundVar,
    Opaque(Symbol),
    Encode(NotDerivableEncode),
    Decode(NotDerivableDecode),
    Eq(NotDerivableEq),
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum NotDerivableEncode {
    Nat,
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum NotDerivableDecode {
    Nat,
    OptionalRecordField(Lowercase),
}

#[derive(PartialEq, Eq, Debug, Clone)]
pub enum NotDerivableEq {
    FloatingPoint,
}
