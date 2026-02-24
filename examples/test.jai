#import "Basic"()(MEMORY_DEBUGGER=true);
#import "File";
#import "Hash_Table";
#import "LSD";
using LS :: #import "Lead_Sheets"()(USING_DYNCALL=false);

Thing :: struct {
    name:      string;
    numbers:   [5] int;
    fraction:  float;
    text:      string;
}

Flags :: enum_flags {
    FIRST;
    SECOND;
    THIRD;
}

main :: () {
    // UA :: #import "Unmapping_Allocator";
    // context.allocator = UA.get_unmapping_allocator();
    defer report_memory_leaks();
    
    things: [..] Thing;
    defer {
        for *things {
            free(it.text);
            free(it.name);
        }
        array_free(things);
    }
    flags: Flags;
    
    add_io_data(Thing, .{
        name_member = "name",
    });
    
    file, ok := read_entire_file("test.gon");
    defer free(file);
    if !ok return;
    
    parser:, ok = parse_file_to_dom(file);
    defer deinit_parser(*parser);
    if !ok return;
    
    add_data_binding_to_dom(*parser, things, "things");
    add_data_binding_to_dom(*parser, flags, "flags");
    
    if !process_data_bindings(*parser) {
        log(format_error(*parser));
        return;
    }
    
    // SERIALIZATION TEST
    // insert_data_node(*parser, "things", things);
    // ok=, output := serialize_to_string(*parser);
    // defer free(output);
    // if ok  print("%\n", output);
    
    print("%\n", things);
    print("%\n", flags);
}

