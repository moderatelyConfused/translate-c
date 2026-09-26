const std = @import("std");

const Attribute = @import("Attribute.zig");
const Compilation = @import("Compilation.zig");

/// Used to implement the __has_feature macro.
pub fn hasFeature(comp: *Compilation, ext_raw: []const u8) bool {
    const ext = Attribute.normalize(ext_raw);

    const list = .{
        .assume_nonnull = true,
        .attribute_analyzer_noreturn = true,
        .attribute_availability = true,
        .attribute_availability_with_message = true,
        .attribute_availability_app_extension = true,
        .attribute_availability_with_version_underscores = true,
        .attribute_availability_tvos = true,
        .attribute_availability_watchos = true,
        .attribute_availability_with_strict = true,
        .attribute_availability_with_replacement = true,
        .attribute_availability_in_templates = true,
        .attribute_availability_swift = true,
        .attribute_cf_returns_not_retained = true,
        .attribute_cf_returns_retained = true,
        .attribute_cf_returns_on_parameters = true,
        .attribute_deprecated_with_message = true,
        .attribute_deprecated_with_replacement = true,
        .attribute_ext_vector_type = true,
        .attribute_ns_returns_not_retained = true,
        .attribute_ns_returns_retained = true,
        .attribute_ns_consumes_self = true,
        .attribute_ns_consumed = true,
        .attribute_cf_consumed = true,
        .attribute_overloadable = true,
        .attribute_unavailable_with_message = true,
        .attribute_unused_on_fields = true,
        .attribute_diagnose_if_objc = true,
        .blocks = comp.langopts.blocks,
        // Objective-C. ARC is deliberately reported as unavailable so that
        // headers keep declaring manual reference counting APIs.
        .objc_arc = false,
        .objc_arc_weak = false,
        .objc_arc_fields = false,
        // `__objc_yes` / `__objc_no` are not supported, so headers should keep
        // defining `YES` / `NO` as casts.
        .objc_bool = false,
        .objc_bridge_id = comp.langopts.objc,
        .objc_bridge_id_on_typedefs = comp.langopts.objc,
        .objc_class_property = comp.langopts.objc,
        .objc_default_synthesize_properties = comp.langopts.objc,
        .objc_fixed_enum = comp.langopts.objc,
        .objc_generics = comp.langopts.objc,
        .objc_generics_variance = comp.langopts.objc,
        .objc_instancetype = comp.langopts.objc,
        .objc_kindof = comp.langopts.objc,
        .objc_nonfragile_abi = comp.langopts.objc,
        .objc_protocol_qualifier_mangling = comp.langopts.objc,
        .c_thread_safety_attributes = true,
        .enumerator_attributes = true,
        .nullability = true,
        .nullability_on_arrays = true,
        .nullability_nullable_result = true,
        .c_alignas = comp.langopts.standard.atLeast(.c11),
        .c_alignof = comp.langopts.standard.atLeast(.c11),
        .c_atomic = comp.langopts.standard.atLeast(.c11),
        .c_generic_selections = comp.langopts.standard.atLeast(.c11),
        .c_static_assert = comp.langopts.standard.atLeast(.c11),
        .c_thread_local = comp.langopts.standard.atLeast(.c11) and comp.target.isTlsSupported(),
        .c_attributes = comp.langopts.standard.atLeast(.c23),
        .c_fixed_enum = comp.langopts.standard.atLeast(.c23),
        .bounds_attributes = comp.langopts.bounds_safety == .clang,
    };
    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, ext)) return @field(list, f.name);
    }
    return false;
}

/// Used to implement the __has_extension macro.
pub fn hasExtension(comp: *Compilation, ext_raw: []const u8) bool {
    const ext = Attribute.normalize(ext_raw);

    // Extensions are a superset of features, so check all features first.
    if (hasFeature(comp, ext)) {
        return true;
    }

    // "-pedantic-errors" effectively disables extensions by erroring out on
    // them, so we just return early. This makes "__has_extension" the same as
    // "__has_feature" when this is set.
    switch (comp.diagnostics.state.extensions) {
        .@"error", .@"fatal error" => return false,
        else => {},
    }

    const list = .{
        // C11 features
        .c_alignas = true,
        .c_alignof = true,
        .c_atomic = true,
        .c_generic_selections = true,
        .c_static_assert = true,
        .c_thread_local = comp.target.isTlsSupported(),
        // C23 features
        .c_attributes = true,
        .c_fixed_enum = true,
        // misc
        .overloadable_unmarked = false, // TODO
        .statement_attributes_with_gnu_syntax = true,
        .gnu_asm = comp.langopts.gnu_asm,
        .gnu_asm_goto_with_outputs = comp.langopts.gnu_asm,
        .matrix_types = false, // TODO
        .matrix_types_scalar_division = false, // TODO
        .define_target_os_macros = comp.langopts.hasTargetOsMacros(),
    };
    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, ext)) return @field(list, f.name);
    }
    return false;
}

/// Attributes that only exist in Objective-C (or that are only useful together
/// with it) and that Apple's headers test with `__has_attribute` before
/// using. They are reported as available in Objective-C mode; the parser
/// still treats them as unknown attributes and ignores them with a warning.
pub fn hasObjcAttribute(name_raw: []const u8) bool {
    const name = Attribute.normalize(name_raw);
    const list = [_][]const u8{
        "objc_bridge",                                    "objc_bridge_mutable",                 "objc_bridge_related",
        "objc_root_class",                                "objc_designated_initializer",         "objc_subclassing_restricted",
        "objc_requires_super",                            "objc_returns_inner_pointer",          "objc_method_family",
        "objc_boxable",                                   "objc_runtime_name",                   "objc_class_stub",
        "objc_direct",                                    "objc_direct_members",                 "objc_non_runtime_protocol",
        "objc_externally_retained",                       "objc_requires_property_definitions",  "objc_exception",
        "objc_protocol_requires_explicit_implementation", "objc_independent_class",              "objc_precise_lifetime",
        "objc_ownership",                                 "objc_arc_weak_reference_unavailable", "objc_nonlazy_class",
        "objc_runtime_visible",                           "objc_non_lazy_class",                 "ns_returns_retained",
        "ns_returns_not_retained",                        "ns_returns_autoreleased",             "ns_consumed",
        "ns_consumes_self",                               "ns_error_domain",                     "cf_returns_retained",
        "cf_returns_not_retained",                        "cf_consumed",                         "cf_audited_transfer",
        "cf_unknown_transfer",                            "swift_name",                          "swift_private",
        "swift_wrapper",                                  "swift_error",                         "swift_bridge",
        "swift_attr",                                     "swift_async",                         "swift_async_error",
        "swift_async_name",                               "swift_newtype",                       "swift_objc_members",
        "swift_bridged_typedef",                          "enum_extensibility",                  "flag_enum",
        "noescape",
    };
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}
