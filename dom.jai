
Field_Flags :: enum_flags {
    // parsing flags
    ARRAY_AS_OBJECT;
    ARRAY_INDEXED;
    ARRAY_ENUMERATED;
    
    PENDING_TYPECHECK;
    EVALUATED;
    
    // formatting flags
    SAME_LINE;
}

Node_Field :: struct {
    using #as 
    base:         Node;
    name:         string;
    value:        *Node;
    binding:      Any;
    field_flags:  Field_Flags;
    
    // still linking field nodes in this manner so that we can more easily insert and append nodes
    next, prev: *Node_Field;
    
    #place scope; parent: *Node_Field;
}

Node_Object :: struct {
    using #as 
    base:   Node;
    fields: Field_List;
    
    #place scope; parent: *Node_Field;
}

Node_Array :: struct {
    using #as 
    base:   Node;
    fields: Field_List;
    
    #place scope; parent: *Node_Field;
}

Field_List :: struct { 
    first:  *Node_Field;
    last:   *Node_Field;
    count:  int;
};

for_expansion :: (list: *Field_List, body: Code, flags: For_Flags) #expand {
    #if flags & .REVERSE {
        `it_index := list.count;
        `it := list.last;
        while it {
            prev := it.prev;
            defer { it = prev; it_index -= 1; }
            #insert(remove={remove_node(it);}) body;
        }
    } else {
        `it_index := 0;
        `it := list.first;
        while it {
            next := it.next;
            defer { it = next; it_index += 1; }
            #insert(remove={remove_node(it);}) body;
        }
    }
}

Reference_Type :: enum {
    VALUE;
    INDEX;
    POINTER;
}

Node_Reference :: struct {
    using #as 
    base:                   Node;
    reference_type:         Reference_Type;
    field_path:             string;
    resolved_field:         *Node_Field;
    resolved_field_index:   Any_Number;
}

get_fields :: inline (field: *Node_Field) -> *Field_List {
    assert(is_aggregate(field));
    return *field.value.(*Node_Object).fields;
}

is_object :: inline (field: *Node_Field) -> bool {
    return field && field.value && field.value.node_type == Node_Object;
}

is_array :: inline (field: *Node_Field) -> bool {
    return field && field.value && field.value.node_type == Node_Array;
}

is_aggregate :: inline (field: *Node_Field) -> bool {
    return field && field.value && field.value && (field.value.node_type == Node_Object || field.value.node_type == Node_Array);
}

Node_Insert_Mode :: enum {
    DEFAULT;        // just insert nodes with no extra checks
    OVERWRITE;      // overwrite existing nodes with the same name
    UNDERWRITE;     // don't insert node if one with the same name already exists
}

get_node_index :: (node: *Node_Field) -> int {
    index := 0;
    n := node.prev;
    while n != null {
        index += 1;
        n = n.prev;
    }
    return index;
}

// TODO: add ability to index array nodes?
// relative path only
find_node_by_path :: (node: *Node_Field, path: string) -> (*Node_Field, int) {
    _path := path;
    index := 0;
    while node != null {
        next:, _path = path_next(_path);
        if next == ".." { 
            node  = node.parent;
            index = get_node_index(node);
        } else {
            node, index = find_child_node_by_name(node, next);
        }
        if !_path  break;
    }
    return node, index;
}

// relative or absolute path
find_node_by_path :: (parser: *Parser, node: *Node_Field, path: string) -> (*Node_Field, int) {
    _path := path;
    if !_path return null, -1;
    search_from_node := node;
    if _path[0] == #char "/" {
        advance(*_path);
        search_from_node = parser.dom_root;
    }
    ret, idx := find_node_by_path(search_from_node, _path);
    return ret, idx;
}

// will return null if not found
find_child_node_by_name :: (parent: *Node_Field, name: string) -> (*Node_Field, int) {
    if !is_aggregate(parent)  return null, -1;
    
    for get_fields(parent)
        if it.name == name  
            return it, it_index;
            
    return null, -1;
}

append_child_node :: (parser: *Parser, parent: *Node_Field, node: *Node_Field, prepend := false) -> *Node_Field {
    return append_child_node(parser, parent.value.(*Node_Object), node, prepend);
}

append_child_node :: (parser: *Parser, array: *Node_Array, node: *Node_Field, prepend := false) -> *Node_Field {
    return append_child_node(parser, array.(*Node_Object), node, prepend);
}
append_child_node :: (parser: *Parser, object: *Node_Object, node: *Node_Field, prepend := false) -> *Node_Field {
    assert(object.node_type == Node_Object || object.node_type == Node_Array, "Node type was %", node.node_type);
    fields := *object.fields; // NOTE: this is valid for both Node_Object and Node_Array
    
    if !node then node = alloc_node(parser, Node_Field);
    
    node.parent = object.parent;
    fields.count += 1;
    
    if prepend {
        if fields.first != null {
            fields.first.prev = node;
            node.next = fields.first;
        }
        fields.first = node;
        
        if fields.last == null {
            fields.last = node;
        }
    } else {
        if fields.last != null {
            fields.last.next = node;
            node.prev = fields.last;
        }
        fields.last = node;
        
        if fields.first == null {
            fields.first = node;
        }
    }
    
    return node;
}

// TODO: maybe we should factor this differently. 
//      It's kind of neat how the 3 behavior cases are all implemented with such minimal logic, 
//      but maybe this is too fragile and hard ot understand.
// NOTE: may be a little bit odd, but if you want tell if a node was overwritten or not, 
//       check if type == .INVALID. if so, then the node was either created or overwritten
get_or_add_child_node :: (parser: *Parser, parent: *Node_Field, name: string, insert_mode: Node_Insert_Mode = .DEFAULT, prepend := false) ->  *Node_Field {
    node: *Node_Field;
    
    if insert_mode != .DEFAULT  node = find_child_node_by_name(parent, name);
    if node == null {
        node = append_child_node(parser, parent, null, prepend);
    }
    else if insert_mode == .UNDERWRITE  return node;
    
    node.* = .{ name = name };
    return node;
}

append_node_with_path :: (parser: *Parser, parent: *Node_Field, path: string, insert_mode: Node_Insert_Mode = .DEFAULT, prepend: bool = false) -> *Node_Field {
    node := parent;
    _path := path;
    while true {
        next:, _path = path_next(_path);
        if !_path  return get_or_add_child_node(parser, node, next, insert_mode, prepend);
        
        child := find_child_node_by_name(node, next);
        if child {
            node = child;
            continue;
        }
        
        node      = append_child_node(parser, node, null, prepend);
        node.name = next;
    }
    
    assert(false, "unreachable");
    return null;
}

remove_node :: (node: *Node_Field) {
    node.parent.count -= 1;
    if node.next != null          node.next.prev    = node.prev;
    if node.prev != null          node.prev.next    = node.next;
    if node.parent.children.first == node  node.parent.children.first = node.next;
    if node.parent.children.last  == node  node.parent.children.last  = node.prev;
}

format_node_path :: (node: *Node_Field) -> string {
    builder: String_Builder;
    append_node_path_to_string_builder(*builder, node);
    return builder_to_string(*builder);
}

append_node_path_to_string_builder :: (builder: *String_Builder, node: *Node_Field) {
    if node.parent != null {
        append_node_path_to_string_builder(builder, node.parent);
        append(builder, "/");
    }
    append(builder, node.name);
}

#scope_module

/*
    Node paths follow essentially the same rules as file paths do on Windows.
    
    Instead of using the lexer to incrementally parse path strings, we just use this one procedure which returns the next path token and the remaining string.
    I was using the lexer for this previously, but in retrospect that was really dumb.
    
    The procedure does not currently do anything special to validate the content of the string, but perhaps we should?
    The caller will also have to check if the path is absolute or relative manually before they start splitting the path.
*/

path_next :: (path: string) -> (next: string, remaining: string, ok: bool) {
    found, left, right := split_from_left_by_any(path, "/\\");
    if !found  return path, "", true;
    return left, right, true;
}

