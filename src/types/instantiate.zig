//! Type instantiation for Hindley-Milner type inference.
//!
//! This module provides functionality to instantiate polymorphic types with fresh
//! type variables while preserving type aliases and structure. This is a critical
//! component for proper handling of annotated functions in the type system.

const std = @import("std");
const base = @import("base");
const collections = @import("collections");

const TypesStore = @import("store.zig").Store;
const Var = @import("types.zig").Var;
const Content = @import("types.zig").Content;
const FlatType = @import("types.zig").FlatType;
const Alias = @import("types.zig").Alias;
const Func = @import("types.zig").Func;
const Record = @import("types.zig").Record;
const TagUnion = @import("types.zig").TagUnion;
const RecordField = @import("types.zig").RecordField;
const Tag = @import("types.zig").Tag;
const Num = @import("types.zig").Num;
const NominalType = @import("types.zig").NominalType;
const Tuple = @import("types.zig").Tuple;
const Rank = @import("types.zig").Rank;
const Mark = @import("types.zig").Mark;
const Ident = base.Ident;

/// Type to manage instantiation.
///
/// Entry point is `instantiateVar`
///
/// This type does not own any of it's fields – it's a convenience wrapper to
/// making threading it's field through all the recursive functions easier
pub const Instantiator = struct {
    // not owned
    store: *TypesStore,
    idents: *const base.Ident.Store,
    var_map: *std.AutoHashMap(Var, Var),

    current_rank: Rank = Rank.top_level,
    rigid_behavior: RigidBehavior,

    /// The mode to use when instantiating
    pub const RigidBehavior = union(enum) {
        /// In this mode, all rigids are instantiated as new flex vars
        /// Note that the the rigid var structure will be preserved.
        /// E.g. `a -> a`, `a` will reference the same new rigid var
        fresh_flex,

        /// In this mode, all rigids are instantiated as new rigid variables
        /// Note that the the rigid var structure will be preserved.
        /// E.g. `a -> a`, `a` will reference the same new flex var
        fresh_rigid,

        /// In this mode, all rigids  we be substituted with values in the provided map.
        /// If a rigid var is not in the map, then that variable will be set to
        /// `.err` & in debug mode it will error
        substitute_rigids: *std.AutoHashMapUnmanaged(Ident.Idx, Var),
    };

    const Self = @This();

    // instantiation //

    /// Instantiate a variable
    pub fn instantiateVar(
        self: *Self,
        initial_var: Var,
    ) std.mem.Allocator.Error!Var {
        const resolved = self.store.resolveVar(initial_var);
        const resolved_var = resolved.var_;

        // Check if we've already instantiated this variable
        if (self.var_map.get(resolved_var)) |fresh_var| {
            return fresh_var;
        }

        switch (resolved.desc.content) {
            .rigid_var => |ident| {
                // If this var is rigid, then create a new var depending on the
                // provided behavior
                const fresh_var = blk: {
                    switch (self.rigid_behavior) {
                        .fresh_rigid => {
                            break :blk try self.store.freshFromContentWithRank(
                                Content{ .rigid_var = ident },
                                self.current_rank,
                            );
                        },
                        .fresh_flex => {
                            break :blk try self.store.freshFromContentWithRank(
                                Content{ .flex_var = null },
                                self.current_rank,
                            );
                        },
                        .substitute_rigids => |rigid_var_subs| {
                            if (rigid_var_subs.get(ident)) |existing_flex_var| {
                                break :blk existing_flex_var;
                            } else {
                                std.debug.assert(false);
                                break :blk try self.store.freshFromContentWithRank(
                                    .err,
                                    self.current_rank,
                                );
                            }
                        },
                    }
                };

                // Remember this substitution for recursive references
                try self.var_map.put(resolved_var, fresh_var);

                return fresh_var;
            },
            else => {
                // Remember this substitution for recursive references
                // IMPORTANT: This has to be inserted _before_ we recurse into `instantiateContent`
                const fresh_var = try self.store.fresh();
                try self.var_map.put(resolved_var, fresh_var);

                // Generate the content
                const fresh_content = try self.instantiateContent(resolved.desc.content);

                // Update the placeholder fresh var with the real content
                try self.store.setVarDesc(
                    fresh_var,
                    .{
                        .content = fresh_content,
                        .rank = self.current_rank,
                        .mark = Mark.none,
                    },
                );

                return fresh_var;
            },
        }
    }

    fn instantiateContent(self: *Self, content: Content) std.mem.Allocator.Error!Content {
        return switch (content) {
            .flex_var => |maybe_ident| Content{ .flex_var = maybe_ident },
            // .rigid_var => |maybe_ident| Content{ .rigid_var = maybe_ident },
            .rigid_var => unreachable,
            .alias => |alias| {
                // Instantiate the structure recursively
                const fresh_alias = try self.instantiateAlias(alias);
                return Content{ .alias = fresh_alias };
            },
            .structure => |flat_type| blk: {
                // Instantiate the structure recursively
                const fresh_flat_type = try self.instantiateFlatType(flat_type);
                break :blk Content{ .structure = fresh_flat_type };
            },
            .err => Content.err,
        };
    }

    fn instantiateAlias(self: *Self, alias: Alias) std.mem.Allocator.Error!Alias {
        var fresh_vars = std.ArrayList(Var).init(self.store.gpa);
        defer fresh_vars.deinit();

        const backing_var = self.store.getAliasBackingVar(alias);
        const fresh_backing_var = try self.instantiateVar(backing_var);
        try fresh_vars.append(fresh_backing_var);

        var iter = self.store.iterAliasArgs(alias);
        while (iter.next()) |arg_var| {
            const fresh_elem = try self.instantiateVar(arg_var);
            try fresh_vars.append(fresh_elem);
        }

        const fresh_vars_range = try self.store.appendVars(fresh_vars.items);
        return Alias{
            .ident = alias.ident,
            .vars = .{ .nonempty = fresh_vars_range },
        };
    }

    fn instantiateFlatType(self: *Self, flat_type: FlatType) std.mem.Allocator.Error!FlatType {
        return switch (flat_type) {
            .str => FlatType.str,
            .box => |box_var| FlatType{ .box = try self.instantiateVar(box_var) },
            .list => |list_var| FlatType{ .list = try self.instantiateVar(list_var) },
            .list_unbound => FlatType.list_unbound,
            .tuple => |tuple| FlatType{ .tuple = try self.instantiateTuple(tuple) },
            .num => |num| FlatType{ .num = try self.instantiateNum(num) },
            .nominal_type => |nominal| FlatType{ .nominal_type = try self.instantiateNominalType(nominal) },
            .fn_pure => |func| FlatType{ .fn_pure = try self.instantiateFunc(func) },
            .fn_effectful => |func| FlatType{ .fn_effectful = try self.instantiateFunc(func) },
            .fn_unbound => |func| FlatType{ .fn_unbound = try self.instantiateFunc(func) },
            .record => |record| FlatType{ .record = try self.instantiateRecord(record) },
            .record_unbound => |fields| FlatType{ .record_unbound = try self.instantiateRecordFields(fields) },
            .empty_record => FlatType.empty_record,
            .tag_union => |tag_union| FlatType{ .tag_union = try self.instantiateTagUnion(tag_union) },
            .empty_tag_union => FlatType.empty_tag_union,
        };
    }

    fn instantiateNominalType(self: *Self, nominal: NominalType) std.mem.Allocator.Error!NominalType {
        var fresh_vars = std.ArrayList(Var).init(self.store.gpa);
        defer fresh_vars.deinit();

        const backing_var = self.store.getNominalBackingVar(nominal);
        const fresh_backing_var = try self.instantiateVar(backing_var);
        try fresh_vars.append(fresh_backing_var);

        var iter = self.store.iterNominalArgs(nominal);
        while (iter.next()) |arg_var| {
            const fresh_elem = try self.instantiateVar(arg_var);
            try fresh_vars.append(fresh_elem);
        }

        const fresh_vars_range = try self.store.appendVars(fresh_vars.items);
        return NominalType{
            .ident = nominal.ident,
            .vars = .{ .nonempty = fresh_vars_range },
            .origin_module = nominal.origin_module,
        };
    }

    fn instantiateTuple(self: *Self, tuple: Tuple) std.mem.Allocator.Error!Tuple {
        const elems_slice = self.store.sliceVars(tuple.elems);
        var fresh_elems = std.ArrayList(Var).init(self.store.gpa);
        defer fresh_elems.deinit();

        for (elems_slice) |elem_var| {
            const fresh_elem = try self.instantiateVar(elem_var);
            try fresh_elems.append(fresh_elem);
        }

        const fresh_elems_range = try self.store.appendVars(fresh_elems.items);
        return Tuple{ .elems = fresh_elems_range };
    }

    fn instantiateNum(self: *Self, num: Num) std.mem.Allocator.Error!Num {
        return switch (num) {
            .num_poly => |poly_var| Num{ .num_poly = try self.instantiateVar(poly_var) },
            .int_poly => |poly_var| Num{ .int_poly = try self.instantiateVar(poly_var) },
            .frac_poly => |poly_var| Num{ .frac_poly = try self.instantiateVar(poly_var) },
            // Concrete types remain unchanged
            .int_precision => |precision| Num{ .int_precision = precision },
            .frac_precision => |precision| Num{ .frac_precision = precision },
            .num_unbound => |unbound| Num{ .num_unbound = unbound },
            .int_unbound => |unbound| Num{ .int_unbound = unbound },
            .frac_unbound => |unbound| Num{ .frac_unbound = unbound },
            .num_compact => |compact| Num{ .num_compact = compact },
        };
    }

    fn instantiateFunc(self: *Self, func: Func) std.mem.Allocator.Error!Func {
        const args_slice = self.store.sliceVars(func.args);
        var fresh_args = std.ArrayList(Var).init(self.store.gpa);
        defer fresh_args.deinit();

        for (args_slice) |arg_var| {
            const fresh_arg = try self.instantiateVar(arg_var);
            try fresh_args.append(fresh_arg);
        }

        const fresh_ret = try self.instantiateVar(func.ret);
        const fresh_args_range = try self.store.appendVars(fresh_args.items);
        return Func{
            .args = fresh_args_range,
            .ret = fresh_ret,
            .needs_instantiation = true,
        };
    }

    fn instantiateRecordFields(self: *Self, fields: RecordField.SafeMultiList.Range) std.mem.Allocator.Error!RecordField.SafeMultiList.Range {
        const fields_slice = self.store.getRecordFieldsSlice(fields);

        var fresh_fields = std.ArrayList(RecordField).init(self.store.gpa);
        defer fresh_fields.deinit();

        for (fields_slice.items(.name), fields_slice.items(.var_)) |name, type_var| {
            const fresh_type = try self.instantiateVar(type_var);
            _ = try fresh_fields.append(RecordField{
                .name = name,
                .var_ = fresh_type,
            });
        }

        return try self.store.appendRecordFields(fresh_fields.items);
    }

    fn instantiateRecord(self: *Self, record: Record) std.mem.Allocator.Error!Record {
        const fields_slice = self.store.getRecordFieldsSlice(record.fields);

        var fresh_fields = std.ArrayList(RecordField).init(self.store.gpa);
        defer fresh_fields.deinit();

        for (fields_slice.items(.name), fields_slice.items(.var_)) |name, type_var| {
            const fresh_type = try self.instantiateVar(type_var);
            _ = try fresh_fields.append(RecordField{
                .name = name,
                .var_ = fresh_type,
            });
        }

        const fields_range = try self.store.appendRecordFields(fresh_fields.items);
        return Record{
            .fields = fields_range,
            .ext = try self.instantiateVar(record.ext),
        };
    }

    fn instantiateTagUnion(self: *Self, tag_union: TagUnion) std.mem.Allocator.Error!TagUnion {
        const tags_slice = self.store.getTagsSlice(tag_union.tags);

        var fresh_tags = std.ArrayList(Tag).init(self.store.gpa);
        defer fresh_tags.deinit();

        for (tags_slice.items(.name), tags_slice.items(.args)) |tag_name, tag_args| {
            var fresh_args = std.ArrayList(Var).init(self.store.gpa);
            defer fresh_args.deinit();

            const args_slice = self.store.sliceVars(tag_args);
            for (args_slice) |arg_var| {
                const fresh_arg = try self.instantiateVar(arg_var);
                try fresh_args.append(fresh_arg);
            }

            const fresh_args_range = try self.store.appendVars(fresh_args.items);

            _ = try fresh_tags.append(Tag{
                .name = tag_name,
                .args = fresh_args_range,
            });
        }

        const tags_range = try self.store.appendTags(fresh_tags.items);
        return TagUnion{
            .tags = tags_range,
            .ext = try self.instantiateVar(tag_union.ext),
        };
    }

    pub fn getIdent(self: *const Self, idx: Ident.Idx) []const u8 {
        return self.idents.getText(idx);
    }
};
