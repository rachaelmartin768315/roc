app "rust-glue"
    packages { pf: "RocType.roc" }
    imports []
    provides [makeGlue] to pf

makeGlue = \types ->
    modFileContent =
        List.walk types "" \content, { target } ->
            archStr = archName target.architecture

            Str.concat
                content
                """
                #[cfg(target_arch = "\(archStr)")]
                mod \(archStr);
                #[cfg(target_arch = "\(archStr)")]
                pub use \(archStr)::*;
                
                """

    types
    |> List.map typesWithDict
    |> List.map convertTypesToFile
    |> List.append { name: "mod.rs", content: modFileContent }
    |> Ok

convertTypesToFile = \types ->
    content =
        walkWithIndex types.types fileHeader \buf, id, type ->
            when type is
                Struct { name, fields } ->
                    generateStruct buf types id name fields Public

                TagUnionPayload { name, fields } ->
                    generateStruct buf types id name (nameTagUnionPayloadFields fields) Private

                TagUnion (Enumeration { name, tags, size }) ->
                    generateEnumeration buf types type name tags size

                TagUnion (NonRecursive { name, tags, discriminantSize, discriminantOffset }) ->
                    if !(List.isEmpty tags) then
                        generateNonRecursiveTagUnion buf types id name tags discriminantSize discriminantOffset None
                    else
                        buf

                TagUnion (Recursive { name, tags, discriminantSize, discriminantOffset }) ->
                    if !(List.isEmpty tags) then
                        generateRecursiveTagUnion buf types id name tags discriminantSize discriminantOffset None
                    else
                        buf

                TagUnion (NullableWrapped { name, indexOfNullTag, tags, discriminantSize, discriminantOffset }) ->
                    generateRecursiveTagUnion buf types id name tags discriminantSize discriminantOffset (Some indexOfNullTag)

                TagUnion (NullableUnwrapped { name, nullTag, nonNullTag, nonNullPayload, whichTagIsNull }) ->
                    generateNullableUnwrapped buf types id name nullTag nonNullTag nonNullPayload whichTagIsNull

                TagUnion (SingleTagStruct { name, tagName, payload }) ->
                    generateSingleTagStruct buf types name tagName payload

                TagUnion (NonNullableUnwrapped { name, tagName, payload }) ->
                    generateRecursiveTagUnion buf types id name [{ name: tagName, payload: Some payload }] 0 0 None

                Function _ ->
                    # TODO: actually generate glue functions.
                    buf

                RecursivePointer _ ->
                    # This is recursively pointing to a type that should already have been added,
                    # so no extra work needs to happen.
                    buf

                Unit
                | Unsized
                | EmptyTagUnion
                | Num _
                | Bool
                | RocResult _ _
                | RocStr
                | RocDict _ _
                | RocSet _
                | RocList _
                | RocBox _ ->
                    # These types don't need to be declared in Rust.
                    # TODO: Eventually we want to generate roc_std. So these types will need to be emitted.
                    buf
    archStr = archName types.target.architecture

    {
        name: "\(archStr).rs",
        content,
    }

generateStruct = \buf, types, id, name, structFields, visibility ->
    escapedName = escapeKW name
    repr =
        length =
            when structFields is
                HasClosure fields -> List.len fields
                HasNoClosure fields -> List.len fields
        if length <= 1 then
            "transparent"
        else
            "C"

    pub =
        when visibility is
            Public -> "pub"
            Private -> ""

    structType = getType types id

    buf
    |> generateDeriveStr types structType IncludeDebug
    |> Str.concat "#[repr(\(repr))]\n\(pub) struct \(escapedName) {\n"
    |> generateStructFields types Public structFields
    |> Str.concat "}\n\n"

generateStructFields = \buf, types, visibility, structFields ->
    when structFields is
        HasNoClosure fields ->
            List.walk fields buf (generateStructFieldWithoutClosure types visibility)
        HasClosure _ ->
            Str.concat buf "// TODO: Struct fields with closures"

generateStructFieldWithoutClosure = \types, visibility ->
    \accum, { name: fieldName, id } ->
        typeStr = typeName types id
        escapedFieldName = escapeKW fieldName

        pub =
            when visibility is
                Public -> "pub"
                Private -> ""

        Str.concat accum "\(indent)\(pub) \(escapedFieldName): \(typeStr),\n"

nameTagUnionPayloadFields = \payloadFields ->
    # Tag union payloads have numbered fields, so we prefix them
    # with an "f" because Rust doesn't allow struct fields to be numbers.
    when payloadFields is
        HasNoClosure fields ->
            renamedFields = List.map fields \{ name, id } -> { name: "f\(name)", id }
            HasNoClosure renamedFields
        HasClosure fields ->
            renamedFields = List.map fields \{ name, id, accessors } -> { name: "f\(name)", id, accessors }
            HasClosure renamedFields

generateEnumeration = \buf, types, enumType, name, tags, tagBytes ->
    escapedName = escapeKW name

    reprBits = tagBytes * 8 |> Num.toStr

    buf
    |> generateDeriveStr types enumType ExcludeDebug
    |> Str.concat "#[repr(u\(reprBits))]\npub enum \(escapedName) {\n"
    |> \b -> walkWithIndex tags b generateEnumTags
    |>
    # Enums require a custom debug impl to ensure naming is identical on all platforms.
    Str.concat
        """
        }

        impl core::fmt::Debug for \(escapedName) {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                match self {
        
        """
    |> \b -> List.walk tags b (generateEnumTagsDebug name)
    |> Str.concat "\(indent)\(indent)}\n\(indent)}\n}\n\n"

generateEnumTags = \accum, index, name ->
    indexStr = Num.toStr index

    Str.concat accum "\(indent)\(name) = \(indexStr),\n"

generateEnumTagsDebug = \name ->
    \accum, tagName ->
        Str.concat accum "\(indent)\(indent)\(indent)Self::\(tagName) => f.write_str(\"\(name)::\(tagName)\"),\n"

generateNonRecursiveTagUnion = \buf, types, id, name, tags, discriminantSize, discriminantOffset, _nullTagIndex ->
    escapedName = escapeKW name
    discriminantName = "discriminant_\(escapedName)"
    discriminantOffsetStr = Num.toStr discriminantOffset
    tagNames = List.map tags \{ name: n } -> n
    # self = "self"
    selfMut = "self"
    # other = "other"
    unionName = escapedName

    buf
    |> generateDiscriminant types discriminantName tagNames discriminantSize
    |> Str.concat "#[repr(C)]\npub union \(unionName) {\n"
    |> \b -> List.walk tags b (generateUnionField types)
    |> generateTagUnionSizer types id tags
    |> Str.concat
        """
        }

        impl \(escapedName) {
            \(discriminantDocComment)
            pub fn discriminant(&self) -> \(discriminantName) {
                unsafe {
                    let bytes = core::mem::transmute::<&Self, &[u8; core::mem::size_of::<Self>()]>(self);

                    core::mem::transmute::<u8, \(discriminantName)>(*bytes.as_ptr().add(\(discriminantOffsetStr)))
                }
            }

            /// Internal helper
            fn set_discriminant(&mut self, discriminant: \(discriminantName)) {
                let discriminant_ptr: *mut \(discriminantName) = (self as *mut \(escapedName)).cast();

                unsafe {
                    *(discriminant_ptr.add(\(discriminantOffsetStr))) = discriminant;
                }
            }
        }

        
        """
    |> Str.concat "// TODO: NonRecursive TagUnion constructor impls\n\n"
    |> \b ->
        type = getType types id
        if cannotDeriveCopy types type then
            # A custom drop impl is only needed when we can't derive copy.
            b
            |> Str.concat
                """
                impl Drop for \(escapedName) {
                    fn drop(&mut self) {
                        // Drop the payloads
                
                """
            |> generateTagUnionDropPayload types selfMut tags discriminantName discriminantSize 2
            |> Str.concat
                """
                    }
                }

                
                """
        else
            b

generateRecursiveTagUnion = \buf, types, id, name, tags, discriminantSize, _discriminantOffset, _nullTagIndex ->
    escapedName = escapeKW name
    discriminantName = "discriminant_\(escapedName)"
    tagNames = List.map tags \{ name: n } -> n
    # self = "(&*self.union_pointer())"
    # selfMut = "(&mut *self.union_pointer())"
    # other = "(&*other.union_pointer())"
    unionName = "union_\(escapedName)"

    buf
    |> generateDiscriminant types discriminantName tagNames discriminantSize
    |> Str.concat
        """
        #[repr(transparent)]
        pub struct \(escapedName) {
            pointer: *mut \(unionName),
        }

        #[repr(C)]
        union \(unionName) {
        """
    |> \b -> List.walk tags b (generateUnionField types)
    |> generateTagUnionSizer types id tags
    |> Str.concat "}\n\n"
    |> Str.concat "// TODO: Recursive TagUnion impls\n\n"

generateTagUnionDropPayload = \buf, types, selfMut, tags, discriminantName, discriminantSize, indents ->
    if discriminantSize == 0 then
        when List.first tags is
            Ok { name } ->
                # There's only one tag, so there's no discriminant and no need to match;
                # just drop the pointer.
                buf
                |> writeIndents indents
                |> Str.concat "unsafe { core::mem::ManuallyDrop::drop(&mut core::ptr::read(self.pointer).\(name)); }"

            Err ListWasEmpty ->
                crash "unreachable"
    else
        buf
        |> writeTagImpls tags discriminantName indents \name, payload ->
            when payload is
                Some id if cannotDeriveCopy types (getType types id) ->
                    "unsafe {{ core::mem::ManuallyDrop::drop(&mut \(selfMut).\(name)) }},"

                _ ->
                    # If it had no payload, or if the payload had no pointers,
                    # there's nothing to clean up, so do `=> {}` for the branch.
                    "{}"

writeIndents = \buf, indents ->
    if indents <= 0 then
        buf
    else
        buf
        |> Str.concat indent
        |> writeIndents (indents - 1)

writeTagImpls = \buf, tags, discriminantName, indents, f ->
    buf
    |> writeIndents indents
    |> Str.concat "match self.discriminant() {\n"
    |> \b -> List.walk tags b \accum, { name, payload } ->
            branchStr = f name payload
            accum
            |> writeIndents (indents + 1)
            |> Str.concat "\(discriminantName)::\(name) => \(branchStr)\n"
    |> writeIndents indents
    |> Str.concat "}\n"

generateTagUnionSizer = \buf, types, id, tags ->
    if List.len tags > 1 then
        # When there's a discriminant (so, multiple tags) and there is
        # no alignment padding after the largest variant,
        # the compiler will make extra room for the discriminant.
        # We need that to be reflected in the overall size of the enum,
        # so add an extra variant with the appropriate size.
        #
        # (Do this even if theoretically shouldn't be necessary, since
        # there's no runtime cost and it more explicitly syncs the
        # union's size with what we think it should be.)
        size = getSizeRoundedToAlignment types id
        sizeStr = Num.toStr size

        Str.concat buf "\(indent)_sizer: [u8; \(sizeStr)],\n"
    else
        buf

generateDiscriminant = \buf, types, name, tags, size ->
    if size > 0 then
        enumType =
            TagUnion
                (
                    Enumeration {
                        name,
                        tags,
                        size,
                    }
                )

        buf
        |> generateEnumeration types enumType name tags size
    else
        buf

generateUnionField = \types ->
    \accum, { name: fieldName, payload } ->
        when payload is
            Some id ->
                typeStr = typeName types id
                escapedFieldName = escapeKW fieldName

                type = getType types id
                fullTypeStr =
                    if cannotDeriveCopy types type then
                        # types with pointers need ManuallyDrop
                        # because rust unions don't (and can't)
                        # know how to drop them automatically!
                        "core::mem::ManuallyDrop<\(typeStr)>"
                    else
                        typeStr

                Str.concat accum "\(indent)\(escapedFieldName): \(fullTypeStr),\n"

            None ->
                # If there's no payload, we don't need a discriminant for it.
                accum

generateNullableUnwrapped = \buf, _types, _id, _name, _nullTag, _nonNullTag, _nonNullPayload, _whichTagIsNull ->
    Str.concat buf "// TODO: TagUnion NullableUnwrapped\n\n"

generateSingleTagStruct = \buf, types, name, tagName, payload ->
    # Store single-tag unions as structs rather than enums,
    # because they have only one alternative. However, still
    # offer the usual tag union APIs.
    escapedName = escapeKW name
    repr =
        length =
            when payload is
                HasClosure fields -> List.len fields
                HasNoClosure fields -> List.len fields
        if length <= 1 then
            "transparent"
        else
            "C"

    when payload is
        HasNoClosure fields ->
            asStructFields =
                List.mapWithIndex fields \{ id }, index ->
                    indexStr = Num.toStr index

                    { name: "f\(indexStr)", id }
                |> HasNoClosure
            asStructType =
                Struct {
                    name,
                    fields: asStructFields,
                }

            buf
            |> generateDeriveStr types asStructType ExcludeDebug
            |> Str.concat "#[repr(\(repr))]\npub struct \(escapedName) "
            |> \b ->
                if List.isEmpty fields then
                    generateZeroElementSingleTagStruct b escapedName tagName
                else
                    generateMultiElementSingleTagStruct b types escapedName tagName fields asStructFields
        HasClosure _ ->
            Str.concat buf "\\TODO: SingleTagStruct with closures"

generateMultiElementSingleTagStruct = \buf, types, name, tagName, payloadFields, asStructFields ->
    buf
    |> Str.concat "{\n"
    |> generateStructFields types Private asStructFields
    |> Str.concat "}\n\n"
    |> Str.concat
        """
        impl \(name) {
        
        """
    |> \b ->
        fieldTypes =
            payloadFields
            |> List.map \{ id } ->
                typeName types id
        args =
            fieldTypes
            |> List.mapWithIndex \fieldTypeName, index ->
                indexStr = Num.toStr index

                "f\(indexStr): \(fieldTypeName)"
        fields =
            payloadFields
            |> List.mapWithIndex \_, index ->
                indexStr = Num.toStr index

                "f\(indexStr)"

        fieldAccesses =
            fields
            |> List.map \field ->
                "self.\(field)"

        {
            b,
            args,
            fields,
            fieldTypes,
            fieldAccesses,
        }
    |> \{ b, args, fields, fieldTypes, fieldAccesses } ->
        argsStr = Str.joinWith args ", "
        fieldsStr = Str.joinWith fields "\n\(indent)\(indent)\(indent)"

        {
            b: Str.concat
                b
                """
                \(indent)/// A tag named ``\(tagName)``, with the given payload.
                \(indent)pub fn \(tagName)(\(argsStr)) -> Self {
                \(indent)    Self {
                \(indent)        \(fieldsStr)
                \(indent)    }
                \(indent)}

                
                """,
            fieldTypes,
            fieldAccesses,
        }
    |> \{ b, fieldTypes, fieldAccesses } ->
        retType = asRustTuple fieldTypes
        retExpr = asRustTuple fieldAccesses

        {
            b: Str.concat
                b
                """
                \(indent)/// Since `\(name)` only has one tag (namely, `\(tagName)`),
                \(indent)/// convert it to `\(tagName)`'s payload.
                \(indent)pub fn into_\(tagName)(self) -> \(retType) {
                \(indent)    \(retExpr)
                \(indent)}

                
                """,
            fieldTypes,
            fieldAccesses,
        }
    |> \{ b, fieldTypes, fieldAccesses } ->
        retType =
            fieldTypes
            |> List.map \ft -> "&\(ft)"
            |> asRustTuple
        retExpr =
            fieldAccesses
            |> List.map \fa -> "&\(fa)"
            |> asRustTuple

        Str.concat
            b
            """
            \(indent)/// Since `\(name)` only has one tag (namely, `\(tagName)`),
            \(indent)/// convert it to `\(tagName)`'s payload.
            \(indent)pub fn as_\(tagName)(&self) -> \(retType) {
            \(indent)    \(retExpr)
            \(indent)}
            
            """
    |> Str.concat
        """
        }


        impl core::fmt::Debug for \(name) {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                f.debug_tuple("\(name)::\(tagName)")
        
        """
    |> \b ->
        payloadFields
        |> List.mapWithIndex \_, index ->
            indexStr = Num.toStr index

            "\(indent)\(indent)\(indent)\(indent).field(&self.f\(indexStr))\n"
        |> List.walk b Str.concat
    |> Str.concat
        """
                        .finish()
            }
        }

        
        """

asRustTuple = \list ->
    # If there is 1 element in the list we just return it
    # Otherwise, we make a proper tuple string.
    joined = Str.joinWith list ", "

    if List.len list == 1 then
        joined
    else
        "(\(joined))"

generateZeroElementSingleTagStruct = \buf, name, tagName ->
    # A single tag with no payload is a zero-sized unit type, so
    # represent it as a zero-sized struct (e.g. "struct Foo()").
    buf
    |> Str.concat "();\n\n"
    |> Str.concat
        """
        impl \(name) {
            /// A tag named \(tagName), which has no payload.
            pub const \(tagName): Self = Self();

            /// Other `into_` methods return a payload, but since \(tagName) tag
            /// has no payload, this does nothing and is only here for completeness.
            pub fn into_\(tagName)(self) {
                ()
            }

            /// Other `as_` methods return a payload, but since \(tagName) tag
            /// has no payload, this does nothing and is only here for completeness.
            pub fn as_\(tagName)(&self) {
                ()
            }
        }

        impl core::fmt::Debug for \(name) {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                f.write_str("\(name)::\(tagName)")
            }
        }

        
        """

generateDeriveStr = \buf, types, type, includeDebug ->
    buf
    |> Str.concat "#[derive(Clone, "
    |> \b ->
        if !(cannotDeriveCopy types type) then
            Str.concat b "Copy, "
        else
            b
    |> \b ->
        if !(cannotDeriveDefault types type) then
            Str.concat b "Default, "
        else
            b
    |> \b ->
        when includeDebug is
            IncludeDebug ->
                Str.concat b "Debug, "

            ExcludeDebug ->
                b
    |> \b ->
        if !(hasFloat types type) then
            Str.concat b "Eq, Ord, Hash, "
        else
            b
    |> Str.concat "PartialEq, PartialOrd)]\n"

cannotDeriveCopy = \types, type ->
    when type is
        Unit | Unsized | EmptyTagUnion | Bool | Num _ | TagUnion (Enumeration _) | Function _ -> Bool.false
        RocStr | RocList _ | RocDict _ _ | RocSet _ | RocBox _ | TagUnion (NullableUnwrapped _) | TagUnion (NullableWrapped _) | TagUnion (Recursive _) | TagUnion (NonNullableUnwrapped _) | RecursivePointer _ -> Bool.true
        TagUnion (SingleTagStruct { payload: HasNoClosure fields }) ->
            List.any fields \{ id } -> cannotDeriveCopy types (getType types id)

        TagUnion (SingleTagStruct { payload: HasClosure fields }) ->
            List.any fields \{ id } -> cannotDeriveCopy types (getType types id)

        TagUnion (NonRecursive { tags }) ->
            List.any tags \{ payload } ->
                when payload is
                    Some id -> cannotDeriveCopy types (getType types id)
                    None -> Bool.false

        RocResult okId errId ->
            cannotDeriveCopy types (getType types okId)
            || cannotDeriveCopy types (getType types errId)

        Struct { fields: HasNoClosure fields } | TagUnionPayload { fields: HasNoClosure fields } ->
            List.any fields \{ id } -> cannotDeriveCopy types (getType types id)

        Struct { fields: HasClosure fields } | TagUnionPayload { fields: HasClosure fields } ->
            List.any fields \{ id } -> cannotDeriveCopy types (getType types id)

cannotDeriveDefault = \types, type ->
    when type is
        Unit | Unsized | EmptyTagUnion | TagUnion _ | RocResult _ _ | RecursivePointer _ | Function _ -> Bool.true
        RocStr | Bool | Num _ | Struct { fields: HasClosure _ } | TagUnionPayload { fields: HasClosure _ } -> Bool.false
        RocList id | RocSet id | RocBox id ->
            cannotDeriveDefault types (getType types id)

        RocDict keyId valId ->
            cannotDeriveCopy types (getType types keyId)
            || cannotDeriveCopy types (getType types valId)

        Struct { fields: HasNoClosure fields } | TagUnionPayload { fields: HasNoClosure fields } ->
            List.any fields \{ id } -> cannotDeriveDefault types (getType types id)

hasFloat = \types, type ->
    hasFloatHelp types type (Set.empty {})

hasFloatHelp = \types, type, doNotRecurse ->
    # TODO: is doNotRecurse problematic? Do we need an updated doNotRecurse for calls up the tree?
    # I think there is a change it really only matters for RecursivePointer, so it may be fine.
    # Otherwise we need to deal with threading through updates to doNotRecurse
    when type is
        Num kind ->
            when kind is
                F32 | F64 -> Bool.true
                _ -> Bool.false

        Unit | Unsized | EmptyTagUnion | RocStr | Bool | TagUnion (Enumeration _) | Function _ -> Bool.false
        RocList id | RocSet id | RocBox id ->
            hasFloatHelp types (getType types id) doNotRecurse

        RocDict id0 id1 | RocResult id0 id1 ->
            hasFloatHelp types (getType types id0) doNotRecurse
            || hasFloatHelp types (getType types id1) doNotRecurse

        Struct { fields: HasNoClosure fields } | TagUnionPayload { fields: HasNoClosure fields } ->
            List.any fields \{ id } -> hasFloatHelp types (getType types id) doNotRecurse

        Struct { fields: HasClosure fields } | TagUnionPayload { fields: HasClosure fields } ->
            List.any fields \{ id } -> hasFloatHelp types (getType types id) doNotRecurse

        TagUnion (SingleTagStruct { payload: HasNoClosure fields }) ->
            List.any fields \{ id } -> hasFloatHelp types (getType types id) doNotRecurse

        TagUnion (SingleTagStruct { payload: HasClosure fields }) ->
            List.any fields \{ id } -> hasFloatHelp types (getType types id) doNotRecurse

        TagUnion (Recursive { tags }) ->
            List.any tags \{ payload } ->
                when payload is
                    Some id -> hasFloatHelp types (getType types id) doNotRecurse
                    None -> Bool.false

        TagUnion (NonRecursive { tags }) ->
            List.any tags \{ payload } ->
                when payload is
                    Some id -> hasFloatHelp types (getType types id) doNotRecurse
                    None -> Bool.false

        TagUnion (NullableWrapped { tags }) ->
            List.any tags \{ payload } ->
                when payload is
                    Some id -> hasFloatHelp types (getType types id) doNotRecurse
                    None -> Bool.false

        TagUnion (NonNullableUnwrapped { payload }) ->
            if Set.contains doNotRecurse payload then
                Bool.false
            else
                nextDoNotRecurse = Set.insert doNotRecurse payload

                hasFloatHelp types (getType types payload) nextDoNotRecurse

        TagUnion (NullableUnwrapped { nonNullPayload }) ->
            if Set.contains doNotRecurse nonNullPayload then
                Bool.false
            else
                nextDoNotRecurse = Set.insert doNotRecurse nonNullPayload

                hasFloatHelp types (getType types nonNullPayload) nextDoNotRecurse

        RecursivePointer payload ->
            if Set.contains doNotRecurse payload then
                Bool.false
            else
                nextDoNotRecurse = Set.insert doNotRecurse payload

                hasFloatHelp types (getType types payload) nextDoNotRecurse

typeName = \types, id ->
    when getType types id is
        Unit -> "()"
        Unsized -> "roc_std::RocList<u8>"
        EmptyTagUnion -> "std::convert::Infallible"
        RocStr -> "roc_std::RocStr"
        Bool -> "bool"
        Num U8 -> "u8"
        Num U16 -> "u16"
        Num U32 -> "u32"
        Num U64 -> "u64"
        Num U128 -> "u128"
        Num I8 -> "i8"
        Num I16 -> "i16"
        Num I32 -> "i32"
        Num I64 -> "i64"
        Num I128 -> "i128"
        Num F32 -> "f32"
        Num F64 -> "f64"
        Num Dec -> "roc_std:RocDec"
        RocDict key value ->
            keyName = typeName types key
            valueName = typeName types value

            "roc_std::RocDict<\(keyName), \(valueName)>"

        RocSet elem ->
            elemName = typeName types elem

            "roc_std::RocSet<\(elemName)>"

        RocList elem ->
            elemName = typeName types elem

            "roc_std::RocList<\(elemName)>"

        RocBox elem ->
            elemName = typeName types elem

            "roc_std::RocBox<\(elemName)>"

        RocResult ok err ->
            okName = typeName types ok
            errName = typeName types err

            "roc_std::RocResult<\(okName), \(errName)>"

        RecursivePointer content ->
            typeName types content

        Struct { name } -> escapeKW name
        TagUnionPayload { name } -> escapeKW name
        TagUnion (NonRecursive { name }) -> escapeKW name
        TagUnion (Recursive { name }) -> escapeKW name
        TagUnion (Enumeration { name }) -> escapeKW name
        TagUnion (NullableWrapped { name }) -> escapeKW name
        TagUnion (NullableUnwrapped { name }) -> escapeKW name
        TagUnion (NonNullableUnwrapped { name }) -> escapeKW name
        TagUnion (SingleTagStruct { name }) -> escapeKW name
        Function { functionName } -> escapeKW functionName

getType = \types, id ->
    when List.get types.types id is
        Ok type -> type
        Err _ -> crash "unreachable"

getSizeRoundedToAlignment = \types, id ->
    alignment = getAlignment types id

    getSizeIgnoringAlignment types id
    |> roundUpToAlignment alignment

getSizeIgnoringAlignment = \types, id ->
    when List.get types.sizes id is
        Ok size -> size
        Err _ -> crash "unreachable"

getAlignment = \types, id ->
    when List.get types.aligns id is
        Ok align -> align
        Err _ -> crash "unreachable"

roundUpToAlignment = \width, alignment ->
    when alignment is
        0 -> width
        1 -> width
        _ ->
            if width % alignment > 0 then
                width + alignment - (width % alignment)
            else
                width

walkWithIndex = \list, originalState, f ->
    stateWithId =
        List.walk list { id: 0nat, state: originalState } \{ id, state }, elem ->
            nextState = f state id elem

            { id: id + 1, state: nextState }

    stateWithId.state

archName = \arch ->
    when arch is
        Aarch32 ->
            "arm"

        Aarch64 ->
            "aarch64"

        Wasm32 ->
            "wasm32"

        X86x32 ->
            "x86"

        X86x64 ->
            "x86_64"

fileHeader =
    """
    // ⚠️ GENERATED CODE ⚠️ - this entire file was generated by the `roc glue` CLI command

    #![allow(unused_unsafe)]
    #![allow(dead_code)]
    #![allow(unused_mut)]
    #![allow(non_snake_case)]
    #![allow(non_camel_case_types)]
    #![allow(non_upper_case_globals)]
    #![allow(clippy::undocumented_unsafe_blocks)]
    #![allow(clippy::redundant_static_lifetimes)]
    #![allow(clippy::unused_unit)]
    #![allow(clippy::missing_safety_doc)]
    #![allow(clippy::let_and_return)]
    #![allow(clippy::missing_safety_doc)]
    #![allow(clippy::redundant_static_lifetimes)]
    #![allow(clippy::needless_borrow)]
    #![allow(clippy::clone_on_copy)]


    
    """

indent = "    "
discriminantDocComment = "/// Returns which variant this tag union holds. Note that this never includes a payload!"

reservedKeywords = Set.fromList [
    "try",
    "abstract",
    "become",
    "box",
    "do",
    "final",
    "macro",
    "override",
    "priv",
    "typeof",
    "unsized",
    "virtual",
    "yield",
    "async",
    "await",
    "dyn",
    "as",
    "break",
    "const",
    "continue",
    "crate",
    "else",
    "enum",
    "extern",
    "false",
    "fn",
    "for",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mod",
    "move",
    "mut",
    "pub",
    "ref",
    "return",
    "self",
    "Self",
    "static",
    "struct",
    "super",
    "trait",
    "true",
    "type",
    "unsafe",
    "use",
    "where",
    "while",
]

escapeKW = \input ->
    # use a raw identifier for this, to prevent a syntax error due to using a reserved keyword.
    # https://doc.rust-lang.org/rust-by-example/compatibility/raw_identifiers.html
    # another design would be to add an underscore after it; this is an experiment!
    if Set.contains reservedKeywords input then
        "r#\(input)"
    else
        input

# This is a temporary helper until roc_std::roc_dict is update.
# after that point, Dict will be passed in directly.
typesWithDict = \{ types, sizes, aligns, typesByName, deps, target } -> {
    types,
    sizes,
    aligns,
    typesByName: Dict.fromList typesByName,
    deps: Dict.fromList deps,
    target,
}
