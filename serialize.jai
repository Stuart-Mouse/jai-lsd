
INDENTATION_STRING :: "    ";

serialize :: (parser: *Parser, builder: *String_Builder) -> bool {
    for get_fields(parser.dom_root)
        if !serialize_dom_node(parser, it, builder, 0)
            return false;
    return true;
}

serialize_to_string :: (parser: *Parser) -> bool, string {
    builder: String_Builder;
    if !serialize(parser, *builder) {
        free_buffers(*builder);
        return false, "";
    }
    return true, builder_to_string(*builder);
}

serialize_to_file :: (parser: *Parser, file_path: string) -> bool {
    builder: String_Builder;
    if !serialize(parser, *builder) {
        free_buffers(*builder);
        return false;
    }
    output_string := builder_to_string(*builder); 
    write_entire_file(file_path, output_string);
    free(output_string);
    return true;
}


Serialize_Flags :: enum_flags {
    NONE :: 0;
    SAME_LINE :: 1;
    SKIP_IF_EMPTY;
    IN_ARRAY;
    IN_INDEXED_ARRAY;
    IS_FIRST_CHILD;
}

// TODO: maybe create some print/serializaiton error in LS that we can use here instead of execution error
serialize_dom_node :: (parser: *Parser, node: *Node_Field, builder: *String_Builder, indent := 0, flags := Serialize_Flags.NONE, enum_index_type: *Type_Info = null) -> bool {
    io_data := get_io_data(node.binding.type);
    
    in_array       := has_flag(flags, .IN_ARRAY);
    is_first_child := has_flag(flags, .IS_FIRST_CHILD);
    same_line      := has_flag(flags, .SAME_LINE);
    
    if (same_line || in_array) && !is_first_child {
        append(builder, ",");
    }
    if same_line {
        append(builder, " ");
    } else {
        append(builder, "\n");
        for 0..indent-1  append(builder, INDENTATION_STRING);
    }
    
    if flags & .IN_INDEXED_ARRAY {
        parent_array := Any_Array.from(node.parent.binding);
        index := get_element_index(parent_array, node.binding.value_pointer);
        print(builder, "%: ", Any.{ ifx enum_index_type else xx int, *index });
    } else if !in_array {
        if is_legal_identifier(node.name) 
            then append(builder, node.name);
            else append_lsd_string(builder, node.name);
        append(builder, ": ");
    }
    
    if node.value == null {
        // TODO: should assert that binding type is appropriate to be printed as a simple field value
        if io_data && io_data.serialize_proc {
            ok, str := io_data.serialize_proc(node.value);
            if !ok {
                set_execution_error(parser, "io_data.serialize_proc failed", node = node);
                return false;
            }
            append(builder, str);
        } else if node.binding.type.type == .STRING {
            append_lsd_string(builder, node.binding.value_pointer.(*string).*);
        } else {
            print_to_builder(builder, "%", node.binding);
        }
        return true;
    }
    
    if is_aggregate(node) {
        same_line ||= io_data && has_flag(io_data.flags, .SERIALIZE_ON_ONE_LINE);
        fields := get_fields(node);
        
        _is_array := is_array(node);
        same_line ||= _is_array && do_sameline_for_type(fields.first.binding.type);
        
        append(builder, ifx _is_array then "[" else "{");
        
        flags: Serialize_Flags = .IS_FIRST_CHILD 
                | (ifx _is_array then .IN_ARRAY)
                | (ifx io_data && has_flag(io_data.flags, .IS_INDEXED_ARRAY) then .IN_INDEXED_ARRAY)
                | (ifx same_line then .SAME_LINE);
                // | (ifx should_skip_empty_elements then .SKIP_IF_EMPTY);
                
        enum_index_type := ifx io_data then io_data.enum_index_type;
        
        for fields {
            if !serialize_dom_node(parser, it, builder, indent + 1, flags, enum_index_type)  return false;
            flags &= ~.IS_FIRST_CHILD;
        }
        
        if same_line {
            append(builder, " ");
        } else {
            append(builder, "\n");
            for 0..indent-1  append(builder, INDENTATION_STRING);
        }
        
        append(builder, ifx _is_array then "]" else "}");
    } else {
        print_node(parser, node.value, builder, indent);
        append(builder, ", ");
    }
    
    return true;
}



insert_data_node :: (parser: *Parser, parent: *Node_Field, path: string, data_binding: Any, prepend: bool = false) -> *Node_Field {    
    node := append_node_with_path(parser, parent, path, prepend = prepend);
    if node == null  return node;
    
    io_data := get_io_data(data_binding.type);
    if io_data && io_data.bind_proc 
        then node.binding = io_data.bind_proc(data_binding);
        else node.binding = data_binding;
    
    assert(node.binding.value_pointer != null);
    
    // NOTE: we don't use the io data of type returned by io_data.bind_proc. But maybe we should, at least for some things.
    // TODO: handle unwrapping of variant types
    binding := node.binding;
    while binding.type.type == .VARIANT {
        binding.type = binding.type.(*Type_Info_Variant).variant_of;
    }
    
    if binding.type.type == {
      case .INTEGER; #through;
      case .FLOAT;   #through;
      case .STRING;  #through;
      case .ENUM;    #through;
      case .BOOL;
        // NOTE: currently leaving node.value null so that we know to serialize data binding directly instead
        return node;
        
      case .ARRAY;
        array := Any_Array.from(binding);
        
        // arrays of bytes/u8 are serialized as string
        // we will probably distinguish this later on u8 vs byte, where byte is serialized using some binary data blob
        if array.element_type.runtime_size == 1 {
            // NOTE: currently leaving node.value null so that we know to serialize data binding directly instead
            return node;
        } else {
            if io_data {
                if io_data.flags & .SERIALIZE_AS_OBJECT {
                    element_io_data := get_io_data(array.element_type);
                    if !element_io_data || !element_io_data.name_member {
                        log("Error: No io data name member defined for type %, path to node: %", as_type(array.element_type), format_node_path(node,, temp));
                        return null;
                    }
                    
                    node.value = alloc_node(parser, Node_Object);
                    // TODO: need to verify that element type is struct and has io data defining name member
                    for array {
                        // TODO: allocation strategy for element_name?
                        element_name: string;
                        name_member_any := get_member(it, element_io_data.name_member);
                        if !Convert.any_to_any(element_name, name_member_any) {
                            log("Error: Unable to get name for element of array: %", format_node_path(node,, temp));
                            return null;
                        }
                        insert_data_node(parser, node, element_name, it);
                    }
                    return node;
                }
                if io_data.flags & .IS_INDEXED_ARRAY {
                    node.value = alloc_node(parser, Node_Object);
                    for array {
                        element_name := tprint("%", it_index);
                        insert_data_node(parser, node, element_name, it);
                    }
                    return node;
                }
            }
            
            node.value = alloc_node(parser, Node_Array);
            for array  insert_data_node(parser, node, "", it);
            return node;
        }
        
      case .STRUCT;
        if io_data && io_data.flags & .SERIALIZE_AS_ARRAY {
            node.value = alloc_node(parser, Node_Array);
            iterate_struct_members(binding, .SKIP_CONSTANT_AND_PLACE, #code {
                insert_data_node(parser, node, "", it);
            });
            return node;
        }
        
        node.value = alloc_node(parser, Node_Object);
        iterate_struct_members(binding, .SKIP_CONSTANT_AND_PLACE, #code {
            insert_data_node(parser, node, it_info.name, it);
        });
    }
    
    return null;
}

do_sameline_for_type :: (ti: *Type_Info) -> bool {
    return ti      == null
        || ti.type == .INTEGER
        || ti.type == .FLOAT
        || ti.type == .ENUM;
}

append_lsd_string :: (builder: *String_Builder, text: string, quote_char: u8 = "\"") -> bool {
    append(builder, quote_char);
    ok := revert_escape_sequences(builder, text);
    append(builder, quote_char);
    return ok;
}