// DATA SEGMENT

INDENTATION_STRING :: "    ";

Serialize_Proc :: #type (*Parser, *Node_Field, *String_Builder, indent: int) -> bool;

serialize :: (parser: *Parser, builder: *String_Builder, proc: Serialize_Proc = serialize_dom_nodes_to_gon) -> bool {
    // manually iterate over root node's children
    // we don't want to call serialize_dom_nodes_to_gon() on the root node because we don't actually want to print that node explicitly
    for get_fields(parser.dom_root)
        if !proc(parser, it, builder, 0)
            return false;
    return true;
}

serialize_to_string :: (parser: *Parser, proc: Serialize_Proc = serialize_dom_nodes_to_gon) -> (result: string, ok: bool) {
    builder: String_Builder;
    if !serialize(parser, *builder, proc)  return "", false;
    return builder_to_string(*builder), true;
}

serialize_to_file :: (parser: *Parser, file_path: string, proc: Serialize_Proc = serialize_dom_nodes_to_gon) -> bool {
    builder: String_Builder;
    if !serialize(parser, *builder, proc)  return false;
    str := builder_to_string(*builder); defer free(str);
    write_entire_file(file_path, str);
    return true;
}


// We could convert this to an iterative process rather than a recursive one relatively easily,
//      because we don't currently have any need to use the stack to hold state.
// May be worth considering later once functionality is more complete.
serialize_dom_nodes_to_gon :: (using parser: *Parser, node: *Node_Field, builder: *String_Builder, indent := 0) -> bool {
    if parser == null || node == null  return false;
    
    in_array       := false;
    is_first_child := false;
    same_line      := false;
    
    if node.parent != null {
        in_array       = is_array(node.parent);
        is_first_child = node == get_fields(node.parent).first;
        same_line      = has_flag(node.parent.field_flags, .SAME_LINE); // check for sameline on parent, not self (we do that later)
    }
    
    if (same_line || in_array) && !is_first_child {
        append(builder, ",");
    }
    if same_line {
        append(builder, " ");
    } else {
        append(builder, "\n");
        for 0..indent-1  append(builder, INDENTATION_STRING);
    }
    
    if !in_array {
        append_gon_string(builder, node.name);
        append(builder, ": ");
    }
    
    if node.value == null {
        // TODO: should assert that binding type is appropriate to be printed as a simple field value
        if node.binding.type.type == .STRING {
            append_gon_string(builder, node.binding.value_pointer.(*string).*);
        } else {
            print_to_builder(builder, "%", node.binding);
        }
    }
    
    if is_aggregate(node) {
        // ensure that end of object/array gets printed on same line if sameline flag is set on self
        same_line ||= has_flag(node.field_flags, .SAME_LINE);
        fields := get_fields(node);
        
        _is_array := is_array(node);
        if _is_array && fields.first && do_sameline_for_type(fields.first.binding.type) {
            node.field_flags |= .SAME_LINE;
            same_line = true;
        }
        
        append(builder, ifx _is_array then "[" else "{");
        
        // recurse for children
        for fields  if !serialize_dom_nodes_to_gon(parser, it, builder, indent + 1)  return false;
        
        if same_line {
            append(builder, " ");
        } else {
            append(builder, "\n");
            for 0..indent-1  append(builder, INDENTATION_STRING);
        }
        
        append(builder, ifx _is_array then "]" else "}");
    } else {
        print_node(parser, node.value, builder, indent);
    }
    
    return true;
}



// TODO: maybe move to serialize.jai, inline determine_node_type_for_serialization and append_nodes_for_indirect_bindings
append_data_node :: (parser: *Parser, parent: *Node_Field, path: string, data_binding: Any, prepend: bool = false) -> *Node_Field {    
    node := append_node_with_path(parser, parent, path, prepend = prepend);
    if node == null  return node;
    
    io_data := get_io_data(data_binding.type);
    if io_data && io_data.bind_proc 
        then node.binding = io_data.bind_proc(data_binding);
        else node.binding = data_binding;
    
    assert(node.binding.value_pointer != null);
    
    io_data = get_io_data(node.binding.type);
    
    // TODO: handle unwrapping of variant types
    
    if node.binding.type.type == {
      case .INTEGER; #through;
      case .FLOAT;   #through;
      case .STRING;  #through;
      case .ENUM;    #through;
      case .BOOL;
        // NOTE: currently leaving node.value null so that we know to serialize data binding directly instead
        return node;
        
      case .ARRAY;
        array := Any_Array.from(node.binding);
        
        // arrays of bytes/u8 are serialized as string
        // we will probably distinguish this later on u8 vs byte, where byte is serialized using some binary data blob
        if array.element_type.runtime_size == 1 {
            // NOTE: currently leaving node.value null so that we know to serialize data binding directly instead
            return node;
        } else {
            if io_data {
                if io_data.flags & .AS_OBJECT {
                    node.value = alloc_node(parser, Node_Object);
                    // need to verify that element type is struct and has io data defining name member
                    return node;
                }
                if io_data.flags & .ARRAY_INDEXED {
                    node.value = alloc_node(parser, Node_Object);
                    for array {
                        elem_name := tprint("%", it_index);
                        append_data_node(parser, node, elem_name, it);
                    }
                    return node;
                }
            }
            
            node.value = alloc_node(parser, Node_Array);
            for array  append_data_node(parser, node, "", it);
            return node;
        }
        
      case .STRUCT;
        if io_data && io_data.flags & .AS_ARRAY {
            node.value = alloc_node(parser, Node_Array);
            iterate_struct_members(node.binding, .SKIP_CONSTANT | .SKIP_PLACE, #code {
                append_data_node(parser, node, "", it);
            });
            return node;
        }
        
        node.value = alloc_node(parser, Node_Object);
        iterate_struct_members(node.binding, .SKIP_CONSTANT | .SKIP_PLACE, #code {
            append_data_node(parser, node, it_info.name, it);
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

append_gon_string :: (builder: *String_Builder, text: string, quote_char: u8 = "\"") -> bool {
    append(builder, quote_char);
    ok := revert_escape_sequences(builder, text);
    append(builder, quote_char);
    return ok;
}