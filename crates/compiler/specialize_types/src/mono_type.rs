use core::num::NonZeroU16;
use soa::{Index, NonEmptySlice, Slice};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MonoTypeId {
    inner: Index<MonoType>,
}

impl MonoTypeId {
    fn new(inner: Index<MonoType>) -> Self {
        Self { inner }
    }
}

pub struct MonoTypes {
    entries: Vec<MonoType>,
    ids: Vec<MonoTypeId>,
    slices: Vec<(NonZeroU16, MonoTypeId)>, // TODO make this a Vec2
}

impl MonoTypes {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            ids: Vec::new(),
            slices: Vec::new(),
        }
    }
    pub fn get(&self, id: MonoTypeId) -> &MonoType {
        todo!("builtins are stored inline");
        // Overall strategy:
        // - Look at the three high bits to figure out which of the 8 MonoTypes we're dealing with
        // - The non-parameterized builtins have 000 as their high bits, and the whole MonoTypeId can be cast to a Primitive.
        // - The parameterized builtins don't need to store a length, just an index. We store that index inline.
        // - The non-builtins all store a length and an index. We store the index inline, and the length out of band.
        //    - Dictionaries store their second param adjacent to the first.
        //    - This means we use 2 bits for discriminant and another 2 bits for which parameterized type it is
        //    - This means we get 29-bit indices, so a maximum of ~500M MonoTypes per module. Should be plenty.
        // - In the future, we can promote common collection types (e.g. List Str, List U8) to Primitives.
    }

    pub(crate) fn add_primitive(&mut self, primitive: Primitive) -> MonoTypeId {
        todo!("if it's one of the hardcoded ones, find the associated MonoTypeId; otherwise, store it etc.");
    }

    pub(crate) fn add_function(
        &mut self,
        ret: Option<MonoTypeId>,
        args: impl IntoIterator<Item = MonoTypeId>,
    ) -> MonoTypeId {
        let mono_type = match ret {
            Some(ret) => {
                let ret_then_args = {
                    let start = self.ids.len();
                    self.ids.push(ret);
                    self.ids.extend(args);
                    // Safety: we definitely have at least 2 elements in here, even if the iterator is empty.
                    let length =
                        unsafe { NonZeroU16::new_unchecked((self.ids.len() - start) as u16) };

                    NonEmptySlice::new(start as u32, length)
                };

                MonoType::Func { ret_then_args }
            }
            None => {
                let args = {
                    let start = self.ids.len();
                    self.ids.extend(args);
                    let length = (self.ids.len() - start) as u16;

                    Slice::new(start as u32, length)
                };

                MonoType::VoidFunc { args }
            }
        };

        let index = self.entries.len();
        self.entries.push(mono_type);
        MonoTypeId::new(Index::new(index as u32))
    }

    /// This should only be given iterators with at least 2 elements in them.
    /// We receive the fields in sorted order (e.g. by record field name or by tuple index).
    /// A later compiler phase will stable-sort them by alignment (we don't deal with alignment here),
    /// and that phase will also sort its DebugInfo struct fields in the same way.
    pub(crate) unsafe fn add_struct_unchecked(
        &mut self,
        fields: impl Iterator<Item = MonoTypeId>,
    ) -> MonoTypeId {
        let start = self.ids.len();
        self.extend_ids(fields);
        let len = self.ids.len() - start;
        let non_empty_slice =
            // Safety: This definitely has at least 2 elements in it, because we just added them.
            unsafe { NonEmptySlice::new_unchecked(start as u32, len as u16)};
        let index = self.entries.len();
        self.entries.push(MonoType::Struct(non_empty_slice));
        MonoTypeId::new(Index::new(index as u32))
    }

    /// We receive the payloads in sorted order (sorted by tag name).
    pub(crate) fn add_tag_union(
        &mut self,
        first_payload: MonoTypeId,
        second_payload: MonoTypeId,
        other_payloads: impl Iterator<Item = MonoTypeId>,
    ) -> MonoTypeId {
        let start = self.ids.len();
        self.ids.push(first_payload);
        self.ids.push(second_payload);
        self.extend_ids(other_payloads);
        let len = self.ids.len() - start;
        let non_empty_slice =
            // Safety: This definiely has at least 2 elements in it, because we just added them.
            unsafe { NonEmptySlice::new_unchecked(start as u32, len as u16)};
        let index = self.entries.len();
        self.entries.push(MonoType::Struct(non_empty_slice));
        MonoTypeId::new(Index::new(index as u32))
    }

    fn extend_ids(&mut self, iter: impl Iterator<Item = MonoTypeId>) -> Slice<MonoTypeId> {
        let start = self.ids.len();
        self.ids.extend(iter);
        let length = self.ids.len() - start;

        Slice::new(start as u32, length as u16)
    }

    pub(crate) fn add(&mut self, entry: MonoType) -> MonoTypeId {
        let id = Index::new(self.entries.len() as u32);

        self.entries.push(entry);

        MonoTypeId { inner: id }
    }
}

// TODO: we can make all of this take up a minimal amount of memory as follows:
// 1. Arrange it so that for each MonoType variant we need at most one length and one start index.
// 2. Store all MonoType discriminants in one array (there are only 5 of them, so u3 is plenty;
//    if we discard record field names, can unify record and tuple and use u2 for the 4 variants)
// 3. Store all the MonoType variant slice lengths in a separate array (u8 should be plenty)
// 4. Store all the MonoType start indices in a separate array (u32 should be plenty)

/// Primitive means "Builtin type that has no type parameters" (so, numbers, Str, and Unit)
///
/// In the future, we may promote common builtin types to Primitives, e.g. List U8, List Str, etc.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Primitive {
    Str,
    Dec,
    F32,
    F64,
    U8,
    I8,
    U16,
    I16,
    U32,
    I32,
    U64,
    I64,
    U128,
    I128,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MonoType {
    Primitive(Primitive),
    Box(MonoTypeId),
    List(MonoTypeId),
    /// Records, tuples, and tag union payloads all end up here. (Empty ones are handled separate.)
    ///
    /// Slice of field types, ordered alphabetically by field name (or by tuple elem index).
    /// The strings for the field names (or tuple indices) are stored out of band in DebugInfo,
    /// which references this MonoTypeId. A later compiler phase will sort these by alignment
    /// (this phase is not aware of alignment), and will sort the DebugInfo structs accordingly.
    Struct(NonEmptySlice<MonoTypeId>),

    /// Slice of payloads, where each payload is a struct or Unit. (Empty tag unions become Unit.)
    ///
    /// These have already been sorted alphabetically by tag name, and the tag name strings
    /// have already been recorded out of band in DebugInfo.
    TagUnion(NonEmptySlice<MonoTypeId>),

    /// A function that has a return value and 0 or more arguments.
    /// To avoid wasting memory, we store the return value first in the nonempty slice,
    /// and then the arguments after it.
    Func {
        ret_then_args: NonEmptySlice<MonoTypeId>,
    },

    /// A function that does not have a return value (e.g. the return value was {}, which
    /// got eliminated), and which has 0 or more arguments.
    /// This has to be its own variant because the other function variant uses one slice to
    /// store the return value followed by the arguments. Without this separate variant,
    /// the other one couldn't distinguish between a function with a return value and 0 arguments,
    /// and a function with 1 argument but no return value.
    VoidFunc {
        args: Slice<MonoTypeId>,
    },
    // This last slot is tentatively reserved for Dict, because in the past we've discussed wanting to
    // implement Dict in Zig (for performance) instead of on top of List, like it is as of this writing.
    //
    // Assuming we do that, Set would still be implemented as a Dict with a unit type for the value,
    // so we would only need one variant for both.
    //
    // The second type param would be stored adjacent to the first, so we only need to store one index.
    // Dict(MonoTypeId),
}
