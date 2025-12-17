
/*
    Add parsing/serialization settings data for all of your data types here at startup.
*/

IO_Data :: struct {
    allocator:          Allocator;
    
    // for structs only
    name_member:        *Type_Info_Struct_Member;
    
    // TODO: do we actually want to have built-in map stuff
    // map_key_member:     *Type_Info_Struct_Member;
    
    // TODO: actually implement!
    member_data:        [] struct { member: *Type_Info_Struct_Member; io_data: IO_Data; };
    
    // for arrays only, can be used to index an array using an enum name
    enum_index_type:    *Type_Info_Enum;
    
    
    bind_proc:  (Any) -> Any;
    parse_proc: (value: Any, text: string) -> bool;
    serialize_proc: (value: Any) -> bool, string;
    
    flags: Flags;
    
    Flags :: enum_flags {
        SKIP_IF_EMPTY;
        SKIP_ELEMS_IF_EMPTY;
        SERIALIZE_AS_ARRAY;
        SERIALIZE_AS_OBJECT;
        SERIALIZE_ON_ONE_LINE;
        IS_INDEXED_ARRAY;
    }
}

IO_Data_Lookup: [..] struct { type: *Type_Info; io_data: IO_Data; };

merge_io_data :: (base: IO_Data, override: IO_Data) -> IO_Data {
    merged: IO_Data;
    
    merged.allocator        = ifx override.allocator.proc then override.allocator else base.allocator;
    merged.name_member      = ifx override.name_member      else base.name_member;
    // merged.map_key_member = ifx override.map_key_member else base.map_key_member;
    
    // TODO: should/can we do this recursively?
    merged.member_data      = ifx override.member_data      else base.member_data;
    
    merged.enum_index_type  = ifx override.enum_index_type  else base.enum_index_type;
    merged.bind_proc        = ifx override.bind_proc        else base.bind_proc;
    merged.parse_proc       = ifx override.parse_proc       else base.parse_proc;
    merged.serialize_proc   = ifx override.serialize_proc   else base.serialize_proc;
    merged.flags            = override.flags | base.flags;
    
    return merged;
}

#scope_module
maybe_override_io_data :: (base: *IO_Data, override: *IO_Data) -> bool #expand {
    if override == null  return false;
    
    merged := merge_io_data(base, override);
    base = *merged;
    return true;
}
#scope_export

add_io_data :: inline (type: Type, io_data: IO_Data) {
    add_io_data(type.(*Type_Info), io_data);
}

add_io_data :: (type: *Type_Info, io_data: IO_Data) {
    for *IO_Data_Lookup
        if it.type == type {
            it.io_data = io_data;
            return;
        }
    
    array_add(*IO_Data_Lookup, .{ type, io_data });
}

get_io_data :: inline (type: *Type_Info) -> *IO_Data {
    for *IO_Data_Lookup
        if it.type == type
            return *it.io_data;
    
    // second pass for polymorphic structs
    if type.type == .STRUCT {
        for *IO_Data_Lookup {
            if type.(*Type_Info_Struct).polymorph_source_struct == xx it.type {
                return *it.io_data;
            }
        }
    }
    
    return null;
}

get_struct_member_io_data :: (io_data: *IO_Data, member: *Type_Info_Struct_Member) -> *IO_Data {
    if io_data == null  return null;
    for *io_data.member_data  
        if it.member == member  
            return *it.io_data;
    return null;
}

get_allocator :: (io_data: *IO_Data) -> Allocator {
    return ifx io_data && io_data.allocator.proc then io_data.allocator else context.allocator;
}
