zig-plain-argparse
=================
A "plain" argument parsing library for Zig.

It parses arguments imperatively (not declaratively), allowing it to reduce compile time magic.

## Features
- Good error messages (full messages beyond builtin zig error codes)
- Zero allocation
- Imperative argument parsing (minimizes comptime complexity)
- Support for subcommands (as a result of simplicity)


## Missing features (TODO?)
- Automatic help generation
  - This would be nice
