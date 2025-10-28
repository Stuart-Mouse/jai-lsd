
/*
    Add parsing/serialization settings data for all of your data types here at startup.
*/

IO_Data :: struct {
    // for structs only
    name_member:        *Type_Info_Struct_Member;
    map_key_member:     *Type_Info_Struct_Member;
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
    for *io_data.member_data  
        if it.member == member  
            return *it.io_data;
    return null;
}


