# Lead Sheets Data (LSD)

A rich data file format for Jai


## Dependencies

This module depends on my Utils module (sorry): https://github.com/Stuart-Mouse/jai-utils
I use this Utils module for many functions which are common across my other modules.


## About

This parser is sort of a fork from my GON parser, which is itself a sort of spin-off dialect of JSON created by by Tyler Glaiel: https://github.com/TylerGlaiel/GON
The implementation, functionality, and even the primary use case of this file format has diverged significantly enough from GON that it seems proper to create a separate repository for this instead of just a branch.

This file format uses my scripting language module (Lead Sheets) in order to allow the user to write arbitrary expressions into their data files, including dynamically calling into native code.
You can think of this this as sort of a "rich data" format, since it allows for real expressiveness.
It's sort of a declarative language, supporting out-of-order evaluation for references between data nodes.
The additional features provided by this format as compared to GON are very useful for rapid iteration, since one can integrate special data loading procedures directly into the files themselves without the need to do post-processing after the initial file load.
While serialization is still technically supported, it's much less practical than in GON, since we're not just dealing with plain old data in all cases.

A primary use case for this kind of data file is for game development, where rapid iteration greatly profits from increased expressivity.
As for myself, I currently use this format in a game engine I am working on to define tilesets, animated color palettes, particle effects, and entity templates.
The ability to use expressions and field references is particulary useful for the player and enemy templates, where I often want to define one value based on another value, or get an index to some named element in an array.
With these added capabilites, data can now be defined in a much more intuitive manner than would otherwise be possible.


## Syntax and Semantics

Like GON, data is structured lexically in terms of objects and arrays (denoted by `{}` and `[]` respectively), as well as simple 'single-valued' fields.
Each field is written as an identifier followed by a colon, followed by a value.
The only exception to this is in the context of an array, in which a series of nameless values are defined.
If you are familiar at all with JSON this should be mostly familiar so far.

Fields:  `<name>: <value>`
Objects: `<name>: { <name>: <value>,  <name>: <value>, ... }`
Arrays:  `<name>: [ <value>, <value>, ... ]`

Unlike JSON, field names need not be contained within quotation marks if they are valid C-style identifiers, and the rules around commas are slightly more lax.

Here's a contrived example to demonstrate some features.
```
    // C-style line and block comments
    
    // Let's define an object for some contrived character...
    "Johnny Appleseed": {
        // simple data is just like in GON or JSON
        age: 34, 
        
        // you can also write expressions like so
        favorite_fraction:  3/47,
        
        // field references can be used as values in expressions 
        dating_cutoff:      $"age" / 2 + 7
        
        // type inference on enum values is supported
        acceptable_colors:  .GREEN | .WHITE | .PURPLE,
        
        // expressions can include procedure calls to any native procedures that are exposed to the parser
        profile_picture:    load_png("data/img/dog_with_a_hat.png"),
    }
}
```


## Features

### Expressiveness

TODO: 

### Field References

TODO: 

### Interaction with Native Code

TODO: 


## Drawbacks

Compared to other POD data formats, there are some drawbacks.

Serilization just makes less sense with a rich data format like this.

Due to the module's use of Dyncall, it currently does not work at compile-time, so if you want to load some data from a file for the purposes of doing code-generation, you'll have to either manually remove that functionality or stick to GON (or JSON or whatever).

Because we are encoding a lot more semantic information that POD files, load times are almost certainly a bit slower. 
However, the Lead Sheets parsing and evaluation are still relatively performant, and for the kind of data you would actually want to define textually like this, the additional load time is essentially negligible.

