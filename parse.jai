#import "Print_Vars";

// used to build a DOM from a text file and evaluate data bindings on that DOM
Parser :: struct {
    using #as script: Script;
    
    // #place script.ast_root;
    dom_root: *Node_Field;
    
    #overlay(current_scope) current_parent: *Node_Field;
};

init_parser :: (parser: *Parser, file: string, file_path := "") {
    init_script(*parser.script);
    
    array_add(*parser.operator_table,
        .{ .PREFIX, "&",  8, "" },
        .{ .PREFIX, "*",  8, "" },
        .{ .PREFIX, "$",  8, "" },
    );
    
    parser.my_parse_leaf     = my_parse_leaf;
    parser.my_parse_binary   = my_parse_binary;
    parser.my_typecheck_node = xx my_typecheck_node;
    parser.my_evaluate_node  = my_evaluate_node;
    parser.my_is_valid_lvalue = my_is_valid_lvalue;
    
    register_common_types(*parser.script);
    
    init_lexer(parser, file, location = .{ file_path, 1, 1 });
    
    parser.dom_root       = alloc_node(parser, Node_Field);
    parser.current_parent = parser.dom_root;
    parser.dom_root.value = alloc_node(parser, Node_Object);
}

deinit_parser :: (parser: *Parser) {
    deinit_script(*parser.script);
}

// creates a dom parser with the given parameters, intializes it, and constructs the dom from the given file
// after calling this, you can just add your data bindings and then process them
parse_file_to_dom :: (file: string, filepath := "") -> (Parser, bool) {
    parser: Parser;
    init_parser(*parser, file, filepath);
    ok := parse_object_contents(*parser, parser.dom_root.value.(*Node_Object), .EOF);
    return parser, ok;
}

add_data_binding_to_dom :: (parser: *Parser, binding: Any, path: string) -> bool {
    node := find_node_by_path(parser.dom_root, path);
    return add_data_binding_to_node(parser, node, binding);
}

add_data_bindings_to_dom :: (parser: *Parser, bindings: [] struct { binding: Any; path: string; }) -> bool {
    for bindings
        if !add_data_binding_to_dom(parser, it.binding, it.path)  
            return false;
    return true;
}

process_data_bindings :: (parser: *Parser) -> bool {
    fields := get_fields(parser.dom_root);
    for fields {
        if !parser.my_typecheck_node(parser, it)  return false;
    }
    for fields {
        parser.my_evaluate_node(parser, it);
        if has_error(parser)  return false;
    }
    return true;
}

add_data_binding_to_node :: (parser: *Parser, node: *Node_Field, binding: Any) -> bool  {
    if node == null || binding.value_pointer == null  return true;
    
    if node.binding.value_pointer != null {
        set_typecheck_error(parser, "node already has data binding set", node = node);
        return false;
    }
    node.binding = binding;
    
    // NOTE: we explicitly do not make bindings for Any, since it should receive whatever type is present lexcally.
    if node.binding.type.type == .ANY  return true;
    
    return add_indirect_bindings_for_aggregate(parser, node, node.value, node.binding);
}

// NOTE: field_node is optional, since we may be applying bindings for an aggregate that is not directly bound to a field
add_indirect_bindings_for_aggregate :: (parser: *Parser, field_node: *Node_Field, value_node: *Node, _binding: Any) -> bool {
    binding := _binding;
    io_data := get_io_data(binding.type);
    
    name_member: Any;
    
    // NOTE: we only check for a name member or bind proc if field_node is present
    if field_node && io_data {
        // because we may rebind the node, we need to assign the name_member Any now
        // if this Any is still set after making bindings to child nodes, then we will assign to it
        if io_data.name_member {
            _, name_member = get_struct_member(binding, io_data.name_member, recursive = true);
        }
        
        if io_data.bind_proc {
            binding = io_data.bind_proc(binding);
            field_node.binding = binding;
            if binding.value_pointer == null {
                set_typecheck_error(parser, "io_data.bind_proc returned null", node = field_node);
                return false;
            }
            // get new io data for new binding
            io_data = get_io_data(binding.type);
        }
    }
    
    defer if name_member.type {
        name_member_io_data := get_io_data(name_member.type);
        if name_member_io_data && name_member_io_data.parse_proc {
            return name_member_io_data.parse_proc(name_member, field_node.name);
        } else {
            return Convert.any_to_any(name_member, field_node.name);
        }
    }
    
    // TODO: think about whether we want to reimplement this functionality
    //       user could probably handle this in bind proc, or we could add some flag to io data
    // node.binding = deref_any_pointer(node.binding);
    
    if value_node.node_type == {
      case Node_Dot;
        dot := value_node.(*Node_Dot);
        if dot.right.node_type == {
          case Node_Object; #through;
          case Node_Array;
            value_node = dot.right;
        }
    }
    
    if value_node.node_type == {
      case Node_Object;
        node_object := value_node.(*Node_Object);
        node_object.value_pointer = binding.value_pointer;
        if binding.type.type == {
          case .ANY;
            // TODO: Need to document this case. Not sure If I just started to implement something here and forgot...
            //       I think the idea here was that we just allow an Any to bind to a struct, but we don't do child bindings.
            
          case .STRUCT;
            structure := Any_Structure.from(binding);
            for node_object.fields {
                found, member, info := get_member(structure, it.name, recursive = true);
                if !found || info.flags & .CONSTANT  continue;
                
                // we don't want to set the name member if the name member has a binding to a child node
                // TODO: If we allow name member to be accessed through a using (which we likely want to do), then we have a problem here.
                //       We can't set the name twice because we will be overwriting whatever string is already there, which is potentially causing a leak of that string.
                //       So, then we have to decide whether to just assume that we can free whatever string is already present (if one is), or we have to track which strings we allocated, so we know not to overwrite them...
                //       OR, we just say fuck it and if the user sets the name twice, then they just cause a leak...
                //       also, the name member is not necessarily a string, so we also can't just check if its non-null and just leave it be
                //       This is probably just a problem with using and multiple bindings generally. I am not sure if there's any good way that we can check that fields are not doubly bound or assigned through using...
                if member.value_pointer == name_member.value_pointer then name_member = Any.{};
                
                if !add_data_binding_to_node(parser, it, member)  return false;
            }
            
            // we don't want to set the name member if the parent exists and is an indexed array, because then the field name is being used for the index
            if field_node && field_node.parent && has_flag(field_node.parent.field_flags, .IS_INDEXED_ARRAY) then name_member = Any.{};
            
            
          case .ARRAY;
            array := Any_Array.from(binding);
            
            if field_node && io_data && has_flag(io_data.flags, .IS_INDEXED_ARRAY) {
                field_node.field_flags |= .IS_INDEXED_ARRAY;
            }
            
            element_io_data := get_io_data(array.element_type);
            
            is_valid_binding := has_flag(field_node.field_flags, .IS_INDEXED_ARRAY);
            if !is_valid_binding {
                is_valid_binding ||= element_io_data != null && element_io_data.name_member != "";
            }
            
            if !is_valid_binding {
                set_typecheck_error(parser, "Object with binding to array type must be indexed or contain a struct type with a name member defined in io_data. Element type was %", as_type(array.element_type), node = value_node);
                return false;
            }
            
            if io_data && has_flag(io_data.flags, .IS_INDEXED_ARRAY) {
                min_index, max_index := S64_MAX, S64_MIN;
                if io_data.enum_index_type {
                    for node_object.fields {
                        ok, index := enum_name_to_value(xx io_data.enum_index_type, it.name);
                        if !ok {
                            set_typecheck_error(parser, "Unable to parse enum value from string: %", it.name, node = value_node);
                            return false;
                        }
                        min_index = min(min_index, index);
                        max_index = max(max_index, index);
                    }
                } else {
                    for node_object.fields {
                        index, ok, remainder := to_integer(it.name);
                        if !ok || remainder {
                            set_typecheck_error(parser, "Unable to parse integer from string: %", it.name, node = value_node);
                            return false;
                        }
                        min_index = min(min_index, index);
                        max_index = max(max_index, index);
                    }
                }
                
                // TODO: add a configurable absolute max index so that we don't resize to some insane amount.
                // TODO: maybe move this check for negative indices into above loops?
                if min_index < 0 || max_index < 0 {
                    set_typecheck_error(parser, "Invalid array index: %, index cannot be negative", min_index, node = value_node);
                    return false;
                }
                if array.array_type == {
                  case .RESIZABLE;
                    resize(array, max_index, true);
                    
                  case .FIXED; #through;
                  case .VIEW;
                    count, data := get_count_and_data(array);
                    if data {
                        if node_object.fields.count > count {
                            set_typecheck_error(parser, "Bounds check failed on fixed array or view. Object contains % elements, but array only contains space for % elements.", node_object.fields.count, count, node = value_node);
                            return false;
                        }
                    } else if array.array_type == .VIEW {
                        assert(count == 0);
                        resize(array, max_index, true);
                    }
                }
                
                if io_data.enum_index_type {
                    for node_object.fields {
                        _, index := enum_name_to_value(xx io_data.enum_index_type, it.name);
                        if !add_data_binding_to_node(parser, it, array[index])  return false;
                    }
                } else {
                    for node_object.fields {
                        index := to_integer(it.name);
                        if !add_data_binding_to_node(parser, it, array[index])  return false;
                    }
                }
            } else {
                count, data := get_count_and_data(array);
                index_offset := 0;
                
                if array.array_type == {
                  case .RESIZABLE;
                    resize(array, count + node_object.fields.count, true);
                    index_offset = count;
                    
                  case .FIXED; #through;
                  case .VIEW;
                    if data {
                        if node_object.fields.count > count {
                            set_typecheck_error(parser, "Bounds check failed on fixed array or view. Object contains % elements, but array only contains space for % elements.", node_object.fields.count, count, node = value_node);
                            return false;
                        }
                    } else if array.array_type == .VIEW {
                        assert(count == 0);
                        resize(array, node_object.fields.count, true);
                    }
                }
                
                for node_object.fields {
                    if !add_data_binding_to_node(parser, it, array[index_offset + it_index])  return false;
                }
            }
            
          case;
            set_typecheck_error(parser, "Cannot bind value of type % to %", as_type(binding.type), node_object.node_type, node = value_node);
            return false;
        }
        
        
      case Node_Array;
        node_array := value_node.(*Node_Array);
        node_array.value_pointer = binding.value_pointer;
        if binding.type.type == {
          case .ANY;
            // TODO: Need to document this case. Not sure If I just started to implement something here and forgot...
            //       I think the idea here was that we just allow an Any to bind to an array, but we don't do child bindings.
            
          case .STRUCT;
            structure := Any_Structure.from(binding);
            
            // TODO: remove this `last_member_offset` logic once #place is fully removed from the language
            member_index := 0;
            last_member_offset := -1;
            for field: node_array.fields {
                // get next assignable field
                member: Any;
                while find_member := true {
                    defer member_index += 1;
                    if member_index >= structure.members.count {
                        set_typecheck_error(parser, "Incorrect number of fields provided for struct. Array contains % elements, but struct contains % elements.", node_array.fields.count, structure.members.count, node = value_node);
                        return false;
                    }
                    
                    member=, info := get_member_by_index(structure, member_index);
                    if info.flags & (.CONSTANT | .OVERLAY)  continue;
                    
                    if info.offset_in_bytes < last_member_offset  break field;
                    last_member_offset = info.offset_in_bytes;
                    
                    break find_member;
                }
                
                if !add_data_binding_to_node(parser, field, member)  return false;
            }
            
            // TODO: should we require that exact number of fields are assigned?
            // if member_index != node_array.fields.count-1 {
            //     set_typecheck_error(parser, "Incorrect number of fields provided for struct. Array contains % elements, but struct contains % elements.", node_array.fields.count, structure.members.count, node = value_node);
            //     return false;
            // }
            
            
          case .ARRAY;
            array := Any_Array.from(binding);
            count, data := get_count_and_data(array);
            index_offset: int; // for dynamic array case, where we want to leave the existing items untouched
            
            if array.array_type == {
              case .RESIZABLE;
                /*
                    IMPORTANT NOTE: 
                    It is critical that the proper amount of space is pre-allocated for the dynamic array 
                    and that we don't have to realloc when we make data bindings for elements below.
                    Because if we realloc then that invalidates the pointers in the data bindings that we created
                    for all previous elements, since those are now pointing to the old locations of each element.
                */
                resize(array, count + node_array.fields.count, true);
                index_offset = count;
                
              case .VIEW;
                if data == null {
                    assert(count == 0);
                    resize(array, node_array.fields.count, true);
                    count = node_array.fields.count; // @HACK: doing this because we read count in the .FIXED case below
                }
                #through;
                
              case .FIXED;
                if node_array.fields.count > count {
                    set_typecheck_error(parser, "Bounds check failed on fixed array or view. Array literal contains % elements, but underlying array only contains space for % elements.", node_array.fields.count, count, node = value_node);
                    return false;
                }
            }
            
            count, data = get_count_and_data(array);
            for node_array.fields {
                if !add_data_binding_to_node(parser, it, array[index_offset + it_index])  return false;
            }
            
          case;
            set_typecheck_error(parser, "Cannot bind value of type % to %", as_type(binding.type), node_array.node_type, node = value_node);
            return false;
        }
    }
    
    return true;
}

// NOTE: Since fields all store their own bindings, we have no need to use the standard hint_storage mechanism for fields and objects.
my_evaluate_node :: (script: *Script, node: *Node, provided_storage: *void = null, flags := Execution_Flags.NONE) -> Any {
    // log("evaluating % @ %", node.node_type, node);
    // log("provided_storage: %", provided_storage);
    // if node.node_type == Node_Field { 
    //     log("field: %", node.(*Node_Field).name);
    //     log("binding: %, %", as_type(node.(*Node_Field).binding.type), node.(*Node_Field).binding.value_pointer);
    // }
    
    return_result :: (node: *Node, any: Any) #expand {
        if provided_storage {
            // log("copying Any.{ %, % } for node % -> provided storage %", as_type(any.type), any.value_pointer, node, provided_storage);
            memcpy(provided_storage, any.value_pointer, any.type.runtime_size);
            `return Any.{ node.value_type, provided_storage };
        }
        
        ok, result := push_any(*script.stack, any, should_push_by_pointer(node));
        if !ok  set_execution_error(script, "Ran out of space on stack!", node = node);
        
        // print("Returning result using stack @ %: ", result.value_pointer);
        // if !is_aggregate(any.type)  print("%", any);
        // print(" (%)", as_type(any.type));
        // print("\n");
        `return result;
    }
    
    if node.node_type == {
      case Node_Reference;
        reference := node.(*Node_Reference).*;
        
        if reference.reference_type == {
          case .VALUE;
            evaluate_node_or_return(script, reference.resolved_field);
            
            resolved_value := reference.resolved_field.binding;
            if resolved_value.type.type == .ANY {
                resolved_value = any_isa(resolved_value, Any).*;
            }
            return_result(node, resolved_value);
            
          case .INDEX; 
            return_result(node, to_any(*reference.resolved_field_index));
        }
        assert(false, "Unhandled reference type.");
        
        
        // NOTE: Node_Field does not itself push anything, it's more like an assignment statement or declaration in that sense
      case Node_Field;
        assert(provided_storage == null);
        field := node.(*Node_Field);
        
        if field.field_flags & .EVALUATED  return VOID_ANY;
        defer field.field_flags |= .EVALUATED;
        
        if field.binding.type == null {
            // set_execution_error(script, "field.binding.type was null", node = node);
            log("field.binding.type was null at %, node: %", get_location(node), field.name);
            return VOID_ANY;
        }
        if field.binding.value_pointer == null {
            // set_execution_error(script, "field.binding.value_pointer was null", node = node);
            return VOID_ANY;
        }
        
        // NOTE: can only use a parse proc when the value type is string
        io_data := get_io_data(field.binding.type);
        if io_data && io_data.parse_proc && field.value.value_type.type == .STRING {
            temp_string: string;
            evaluate_node_or_return(script, field.value, *temp_string);
            
            if !io_data.parse_proc(field.binding, temp_string) {
                set_execution_error(script, "io_data.parse_proc returned false for field '%' with value '%'.", field.name, temp_string, node = node);
                return NULL_ANY;
            }
            return VOID_ANY;
        }
        
        binding := field.binding;
        if field.binding.type.type == .ANY {
            value_type := field.value.value_type;
            
            io_data := get_io_data(value_type);
            if io_data == null  io_data = get_io_data(xx Any);
            allocator := get_allocator(io_data);
            
            any_ptr := any_isa(field.binding, Any);
            any_ptr.* = New_Any(value_type,, allocator);
            binding = any_ptr.*;
        }
        
        evaluate_node_or_return(script, field.value, binding.value_pointer);
        if binding.type.type == .STRING {
            any_isa(binding, string).* = copy_string(any_isa(binding, string).*);
        }
        return VOID_ANY;
        
        
      case Node_Array; #through;
      case Node_Object;
        object := node.(*Node_Object);
        assert(node.scope.node_type == Node_Field, "%, %", node.scope.node_type, node.scope == script.ast_root);
        
        // TODO: this assumption will very likely need to change
        // but for now the assumption is that all fields will pass their *functional* value pointer to the value expression
        // this is primarily so that we can correctly assign values to Anys
        // later, we will probably need to ensure that all fields within an aggregate have bindings to some parent object allocated for the aggregate (if the aggregate indeed needs some temporary value)
        // maybe we can just use get_result_storage for that after all...? (but fields need their bindings at typecheck time... AAAUUUGHH)
        value_pointer := ifx object.value_pointer else provided_storage;
        assert(value_pointer != null);
        
        for object.fields  evaluate_node_or_return(script, it);
        
        binding := Any.{ object.value_type, value_pointer };
        return_result(object, binding);
        
        
      case Node_Dot;
        dot := node.(*Node_Dot);
        // special case to provide proper type hint to aggregate node
        if dot.right.node_type == Node_Object
        || dot.right.node_type == Node_Array {
            return script.my_evaluate_node(script, dot.right, provided_storage, flags);
        }
        // else just evaluate node using standard procedure
    }
    
    // the node wasn't any of our special types, so default to the standard evaluate_node
    return evaluate_node(script, node, provided_storage, flags);
}

my_typecheck_node :: (
    parser:         *Parser,
    node:           *Node, 
    check_flags:    Typechecking_Flags = .NONE,
    hint_type:      *Type_Info         = null
) -> (
    value_type:     *Type_Info
) {
    if node.node_type == {
      case Node_Field;
        field := node.(*Node_Field);
        
        // we set value_type for the sake of typechecking, but Node_Field does not actually return any value when executed.
        field.flags |= .VALUE_TYPE_IS_NOMINAL;
        
        if field.binding.type == null {
            // if hint_type {
            //     // create impromptu filler binding if we have a hint type
            //     // this allows for aggregate literals to be used in arbitrary expressions
            //     temp_binding := New_Any(hint_type,, LS.get_pool_allocator(*parser.pool));
            //     if !add_data_binding_to_node(parser, field, temp_binding)  return null;
            // } else {
                field.value_type = type_info(void);
                return field.value_type;
            // }
        }
        
        // TODO: could create cyclic dependency error type and just check this error type to print all pending nodes on the way back up the call stack
        // We set the PENDING_DEPENDENCY flag on this node only for the duration of this call
        //      so that we know if we visit it again, we have gone in a loop.
        // TODO: would be better if we explicitly track the dependency chain so that we can print a better error here
        if field.field_flags & .PENDING_TYPECHECK {
            set_general_error(parser, "Cyclic dependency on node '%'.", format_node_path(field,, temp), loc = node.location);
            return null;
        }
        field.field_flags |= .PENDING_TYPECHECK;
        defer field.field_flags &= ~.PENDING_TYPECHECK;
        
        defer_restore(*parser.current_parent);
        parser.current_parent = field;
        
        value_type := parser.my_typecheck_node(parser, field.value, hint_type = field.binding.type);
        if !value_type  return null;
        
        // NOTE: if an io data parse proc is present, then the value_type of the RHS can always be a string
        //       this will not affect the value type of the field itself, which will still just be the binding's type
        // io_data := get_io_data(field.binding.type);
        // can_use_io_data_parse_proc := io_data != null && io_data.parse_proc != null && value_type.type == .STRING;
        
        // if field.binding.type.type != .ANY 
        // && field.binding.type != value_type 
        // && !can_use_io_data_parse_proc {
        //     set_general_error(parser, "Mismatched types on field binding and value expression. Expected %, got %.", as_type(field.binding.type), as_type(value_type), loc = node.location);
        //     return null;
        // }
        
        field.value_type = field.binding.type;
        field.flags |= .TYPECHECKED;
        return field.value_type;
        
      case Node_Dot;
        dot := node.(*Node_Dot);
        // special case to provide proper type hint to aggregate node
        if dot.right.node_type == Node_Object
        || dot.right.node_type == Node_Array {
            left_type := parser.my_typecheck_node(parser, dot.left);
            if has_error(parser)  return null;
            if left_type.type != .TYPE {
                set_typecheck_error(parser, "Left-hand side of dot-aggregate expression must be a type.", node = dot.left);
                return null;
            }
            
            if !(dot.left.flags & .IS_CONSTANT) {
                set_typecheck_error(parser, "Type expression on left-hand side of dot operator must be constant.", node = dot);
                return null;
            }
            
            my_evaluate_node(parser, dot.left);
            if has_error(parser)  return null;
            namespace := pop_as(*parser.stack, *Type_Info);
            
            if namespace.type == {
              case .STRUCT; #through;
              case .ARRAY;
                right_type := parser.my_typecheck_node(parser, dot.right, hint_type = namespace);
                if has_error(parser)  return null;
                assert(namespace == right_type, "Type returned by right side of aggregate literal (%) expression did not match type specified on left side of dot (%)", as_type(right_type), as_type(namespace));
                dot.value_type = namespace;
                dot.flags |= .TYPECHECKED;
                return dot.value_type;
                
              case;
                set_typecheck_error(parser, "Type % cannot be used for an aggregate literal.", namespace, node = dot);
                return null;
            }
        }
        // else just typecheck node using standard procedure
        
      case Node_Object; #through;
      case Node_Array;
        object := node.(*Node_Object);
        if hint_type == null {
            set_typecheck_error(parser, "Missing type hint on %.", node.node_type, node = node, type = .MISSING_TYPE_HINT, loc = node.location);
            return null;
        }
        object.value_type = hint_type;
        
        if !object.value_pointer {
            object.value_pointer = Dynamic_New(object.value_type);
            if !add_indirect_bindings_for_aggregate(parser, null, object, Any.{ object.value_type, object.value_pointer })  return null;
        }
        
        for object.fields {
            if !parser.my_typecheck_node(parser, it)  return null;
        }
        object.flags |= .TYPECHECKED;
        return object.value_type;
        
        
      case Node_Reference;
        reference := node.(*Node_Reference);
        field := parser.current_parent.(*Node_Field);
        
        resolved_field, resolved_index := find_node_by_path(xx parser, field.parent, reference.field_path);
        if resolved_field == null {
            set_typecheck_error(parser, "Unable to resolve referenced node path '%'.", reference.field_path, node = node, loc = node.location);
            return null; 
        }
        reference.resolved_field = resolved_field;
        reference.resolved_field_index = Any_Number.from(resolved_index);
        
        // TODO: probably make this a evaluation error
        if reference.resolved_field.binding.value_pointer == null {
            // TODO: handle this case by creating temporary instance of hinted type?
            //       (this would have to use type hint of referrer, since the referenced field obviously would not have a type hint)
            set_general_error(parser, "Referenced node '%' had no data binding!.", reference.field_path, loc = reference.location);
            return null;
        }
        
        // jump to referenced node
        if !parser.my_typecheck_node(parser, reference.resolved_field)  return null;
        
        if reference.reference_type == {
          case .VALUE; reference.value_type = reference.resolved_field.binding.type;
          case .INDEX; 
            reference.value_type = type_info(int);
            if hint_type {
                reference.value_type = hint_type;
                // convert reference.resolved_field_index to the hinted type and store back into same place
                Convert.any_to_any(Any.{ reference.value_type, *reference.resolved_field_index.value }, to_any(*reference.resolved_field_index));
            }
        }
        reference.flags |= .TYPECHECKED;
        return reference.value_type;
    }
    
    // defer to default typecheck_node if it wasn't one out our special node types
    return typecheck_node(parser, node, check_flags, hint_type);
}


make_reference :: (script: *Script, type: Reference_Type, path: string) -> *Node_Reference {
    ref := alloc_node(script, Node_Reference);
    ref.reference_type = type;
    ref.field_path     = path;
    return ref;
}

// Custom versions of parse_leaf and parse_binary are implemented here to remove some of the LS features which we do not want to use in LSD.

my_parse_leaf :: (using script: *Script) -> *Node {
    token := get_token(script);
    
    is_operator, operator_index := get_prefix_operator(script, token);
    if is_operator {
        _operator := get_operator(script, operator_index);
        // special cases, bit of a parsing hack for the field reference operators
        // maybe later we will add the ability to have comptime operators more generally
        if token.text == {
          case "$";
            string_token := get_token(script);
            if string_token.type != .STRING {
                set_parse_error(script, "Expected a path string after node reference operator.", loc = token.location);
                return null;
            }
            return make_reference(script, .VALUE, string_token.text);
            
          case "&";
            string_token := get_token(script);
            if string_token.type != .STRING {
                set_parse_error(script, "Expected a path string after node reference operator.", loc = token.location);
                return null;
            }
            return make_reference(script, .INDEX, string_token.text);
        }
        
        left := my_parse_expression(script, _operator.precedence);
        if left == null  return null;
        return make_operation(script, token, operator_index, left, null);
    }
    
    if token.type == {
      case .DOT;
        token_after_dot := get_token(script);
        if token_after_dot.type == .IDENTIFIER {
            identifier := make_identifier(script, token_after_dot);
            return make_dot(script, token, null, identifier);
        } else {
            set_parse_error(script, "Unexpected % token '%' after unary dot.", token_after_dot.type, token_after_dot.text, loc = token_after_dot.location);
            return null;
        }
        
      case .OPEN_PAREN;
        open_paren_location := token.location;
        
        expression := my_parse_expression(script, 0);
        if expression == null  return null;
        expression.flags |= .PARENTHESIZED;
        
        close_paren_token := get_token(script);
        if close_paren_token.type != .CLOSE_PAREN {
            set_parse_error(script, "Expected a closing paren for open paren at %.", open_paren_location, loc = close_paren_token.location);
            return null;
        }
        return expression;
        
      case .OPEN_BRACE;
        object := alloc_node(script, Node_Object, loc = token.location);
        object.(*Node_Object).parent = xx script.current_scope;
        assert(script.current_scope.node_type == Node_Field);
        if !parse_object_contents(xx script, object)  return null;
        return object;
        
      case .OPEN_BRACKET;
        array := alloc_node(script, Node_Array, loc = token.location);
        array.(*Node_Array).parent = xx script.current_scope;
        assert(script.current_scope.node_type == Node_Field);
        if !parse_array_contents(xx script, array)  return null;
        return array;
        
      case .TRUE;
        literal := alloc_node(script, Node_Literal, loc = token.location, trivia = token.trivia);
        literal.literal_type = .BOOLEAN;
        literal.number       = to_any_number(true);
        return literal;
        
      case .FALSE;
        literal := alloc_node(script, Node_Literal, loc = token.location, trivia = token.trivia);
        literal.literal_type = .BOOLEAN;
        literal.number       = to_any_number(false);
        return literal;
        
      case .NUMBER;
        return make_number_literal(script, token);
        
      case .STRING;
        return make_string_literal(script, token);
        
      case .IDENTIFIER;
        return make_identifier(script, token);
        
      case .DIRECTIVE;
        directive := alloc_node(script, Node_Directive, loc = token.location, trivia = token.trivia);
        directive.name = token.text;
        
        directive.directive_index = -1;
        for script.directives {
            if it.name == directive.name {
                directive.directive_index = it_index;
            }
        }
        if directive.directive_index == -1 {
            set_parse_error(script, "Unable to resolve directive '%'\n", directive.name, loc = directive.location);
            return null;
        }
        
        open_paren_token := get_token(script);
        if open_paren_token.type != .OPEN_PAREN {
            set_parse_error(script, "Expected an open paren after directive name!\n", loc = open_paren_token.location);
            return null;
        }
        
        if !expect_token_type(script, .CLOSE_PAREN) {
            expressions := parse_comma_separated_expressions(script,, temp);
            if !expressions  return null;
            directive.arguments = array_copy(expressions,, LS.get_pool_allocator(*script.pool));
            
            close_paren_token := get_token(script);
            if close_paren_token.type != .CLOSE_PAREN {
                set_parse_error(script, "Expected a closing paren after arguments of directive. Instead we saw %\n", close_paren_token.text, loc = close_paren_token.location);
                return null;
            }
        }
        
        if !evaluate_directive(script, directive, .PARSE) {
            set_parse_error(script, "Failed while trying to execute a directive during parsing.", loc = token.location, node = directive);
            return null;
        }
        return directive;
    }
    
    return null;
}

my_parse_binary :: (using script: *Script, left: *Node, min_prec: int) -> *Node {
    token := peek_token(script);
    
    // In addition to normal binary operators, we have a few binary-operator-like constructs that have essentially infinite operator precedence.
    // These are open parenthesis for procedure calls, dot for struct member access and cast, and open bracket for array indexing.
    if token.type == {
      case .OPEN_PAREN;
        get_token(script);
        arg_exprs, ok := parse_procedure_arguments(script);
        if !ok  return null;
        return make_procedure_call(script, token, left, arg_exprs);
        
        
      case .DOT;
        dot_token := get_token(script);
        
        token_after_dot := get_token(script);
        if token_after_dot.type == {
          case .IDENTIFIER;
            identifier := make_identifier(script, token_after_dot);
            return make_dot(script, dot_token, left, identifier);
            
          case .OPEN_PAREN;
            type_expr := my_parse_expression(script, 0);
            close_paren := get_token(script);
            if close_paren.type != .CLOSE_PAREN {
                set_parse_error(script, "Unexpected token '%' in cast type expression. Expected a closing paren.", close_paren.type, loc = close_paren.location);
                return null;
            }
            return make_cast(script, dot_token, left, type_expr);
            
          case .OPEN_BRACE;
            object := alloc_node(script, Node_Object, loc = token.location);
            object.(*Node_Object).parent = xx script.current_scope;
            assert(script.current_scope.node_type == Node_Field);
            if !parse_object_contents(xx script, object)  return null;
            return make_dot(script, dot_token, left, object);
            
          case .OPEN_BRACKET;
            array := alloc_node(script, Node_Array, loc = token.location);
            array.(*Node_Array).parent = xx script.current_scope;
            assert(script.current_scope.node_type == Node_Field);
            if !parse_array_contents(xx script, array)  return null;
            return make_dot(script, dot_token, left, array);
        }
        
        set_parse_error(script, "Unexpected % token '%' after dot.", token.type, token.text, loc = token.location);
        return null;
        
        
      case .OPEN_BRACKET;
        open_bracket_token := get_token(script);
        
        indexing_expr := my_parse_expression(script, 0);
        if indexing_expr == null  return null;
        if !expect_token_type(script, .CLOSE_BRACKET)  return null;
        
        return make_subscript(script, open_bracket_token, left, indexing_expr);
    }
    
    // We only consume the binary operator here if it is of a higher precedence than the previous binary operator.
    // If we hit a binary operator but its precedence is too low, we return left back to caller.
    is_operator, operator_index := get_binary_operator(script, token);
    if is_operator {
        _operator := get_operator(script, operator_index);
        if _operator.precedence <= min_prec  return left;
        
        operator_token := get_token(script);
        right := my_parse_expression(script, _operator.precedence);
        if right == null  return null;
        
        return make_operation(script, operator_token, operator_index, left, right);
    }
    
    return left;
}

my_is_valid_lvalue :: (script: *Script, node: *Node, need_lvalue := false, set_as_lvalue := false) -> bool {
    need_lvalue ||= set_as_lvalue;
    if set_as_lvalue then node.flags |= .PUSH_BY_POINTER;
    
    if node.node_type == {
      case Node_Field;
        if need_lvalue then set_typecheck_error(script, "A Node_Field cannot be used as an lvalue.", node = node);
        return false;
        
      case Node_Object;
        if need_lvalue then set_typecheck_error(script, "A Node_Object cannot be used as an lvalue.", node = node);
        return false;
        
      case Node_Array;
        if need_lvalue then set_typecheck_error(script, "A Node_Array cannot be used as an lvalue.", node = node);
        return false;
        
      case Node_Reference;
        if need_lvalue then set_typecheck_error(script, "A field reference cannot be used as an lvalue.", node = node);
        return false;
    }
    
    return is_valid_lvalue(script, node, need_lvalue, set_as_lvalue);
}

parse_field :: (parser: *Parser, parent_is_object: bool) -> *Node_Field {
    node := alloc_node(parser, Node_Field);
    node.parent = parser.current_parent;
    parser.current_parent = node;
    
    if parent_is_object {
        name_token := get_token(parser);
        node.location = name_token.location;
        
        if name_token.type == {
          case .IDENTIFIER; #through;
          case .STRING;
            node.name   = name_token.text;
            node.trivia = name_token.trivia;
            
            next_token := get_token(parser);
            if next_token.type != .COLON {
                set_parse_error(parser, "Expected colon after field name '%', got % \"%\"", name_token.text, next_token.type, next_token.text, node = node);
                return null;
            }
            
          case;
            set_parse_error(parser, "Expected a field name, but saw this instead: % (%)", name_token.text, name_token.type, node = node);
            return null;
        }
    } else {
        node.location = parser.lexer.location;
    }
    
    node.value = parser.my_parse_expression(parser, 0);
    
    if node.value == null {
        log("LSD parse error: failed to parse expression @ %", node.location);
        log(format_error(parser));
        return null;
    }
    // assert(node.value != null, "%: Node value was null, but no script error was set.", LS.get_location(node));
    
    if !parent_is_object {
        node.location = node.value.location;
    }
    
    next_token := peek_token(parser);
    if next_token.type == {
      case .CLOSE_BRACE;
      case .CLOSE_BRACKET;
      case .EOF;
      case .COMMA; get_token(parser);
      case;
        set_parse_error(parser, "Unexpected % token, expected end of scope or expression delimiter.", next_token.type, node = node);
        return null;
    }
    
    parser.current_parent = node.parent;
    return node;
}

// TODO: these should really work more like parse_contents_of_struct_literal

parse_array_contents :: (using parser: *Parser, array: *Node_Array) -> bool {
    while !expect_token_type(*script, .CLOSE_BRACKET) {
        field := parse_field(parser, false);
        if !field  return false;
        append_child_node(parser, array, field);
    }
    return true;
}

parse_object_contents :: (using parser: *Parser, object: *Node_Object, scope_end_token := Token_Type.CLOSE_BRACE) -> bool {
    while !expect_token_type(*script, scope_end_token) {
        field := parse_field(parser, true);
        if !field  return false;
        append_child_node(parser, object, field);
    }
    return true;
}
