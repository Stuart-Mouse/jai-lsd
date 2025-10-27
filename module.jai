
/*
    'parser' gets exported to caller, not sure if I like this or not, since it then exists outside macro, 
    and I really only want it scoped so that inserted code can see it, like how a for_expansion works..
    I would also like to be able to have the LS and GON procedures be usable without qualified names here...
*/
load_and_parse_file :: (path: string, code: Code) -> bool #expand {
    file, file_ok := read_entire_file(path);
    if !file_ok {
        log("Unable to open gon file '%'!", path);
        return false;
    }
    defer free(file);
    
    `parser, parser_ok := parse_file_to_dom(file, path);
    defer deinit_parser(*parser);
    if !parser_ok {
        log("Unable to parse gon file '%'!", path);
        log(format_error(parser)); 
        return false;
    }
    
    #insert code;
    
    if !process_data_bindings(*parser)  {
        log("Failed to process data bindings for gon file '%'!", path);
        log(format_error(parser)); 
        return false;
    }
    
    return true;
}


#load "dom.jai";
#load "parse.jai";
#load "serialize.jai";
#load "io_data.jai";

#scope_module

#import "Basic";
#import "Math";
#import "File";
#import "Reflection";
#import "String";
#import "Flat_Pool";

#import "Utils";
Convert  :: #import "Convert";
using LS :: #import "Lead_Sheets";


