zig-plain-argparse
=================
[WIP] A "plain" argument parsing library for Zig.

The key feature is that it parses arguments imperatively (not declaratively).

This makes it lower-level than [zig-clap](https://github.com/Hejsil/zig-clap), which is more declarative (and probably better for general use).

## Motiviation
Hopefully this more imperitive design reduce the amount of compile time magic . :)

I couldn't understand zig-clap well enough to implement "proper" subcommands.

In this more imperative style of parsing, subcommands are not a problem because they are just positional values.

You can parse a subcommand as a Zig enum, then create a new parser for the remaining arguments.

Also another plus side is zero allocation ;)

## Features
- Good error messages (descriptive errors)
- Zero allocation (`Parser` is a thin wrapper around `[][]const u8`)
- Imperative argument parsing (hopefully) minimizes comptime complexity
- Support for subcommands follows nicely from the simplicity
   - See examples for this (TODO)


## Missing features (TODO?)
- Automatic help generation
  - This would be nice
- More tests
