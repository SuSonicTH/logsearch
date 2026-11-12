# LogSearch

LogSearch is a small, fast command line tool for reading and filtering (Java) logfiles.
It understands the usual log line layout of a timestamp, a level and a logger/class name,
followed by the actual message, and lets you filter on any of those parts.

The tool memory-maps the input files, so even large logfiles can be searched without
loading them into memory up front. Lines that do not start a new log entry (for example
stack traces or wrapped messages) are kept as part of the preceding entry.

## Features

- Filter by log level, class/logger name and message content
- Multiple files can be searched in a single run
- Message filtering uses regular expressions
- Levels, classes and searches are repeatable and combined with OR within a category
- Configurable patterns for non-standard log formats
- Multiline entries (stack traces) are preserved
- Single small binary with no runtime dependencies

## Requirements

- [Zig](https://ziglang.org/) 0.17.0 or newer (only needed to build from source)

## Building

Build the native binary with Zig:

```sh
zig build -Doptimize=fast
```

The binary is written to `zig-out/bin/logsearch`.

The build also supports cross compilation and compressed release binaries:

```sh
zig build test      # run the tests
zig build native    # optimized, UPX-compressed binary for the host
zig build release   # compressed binaries for all supported platforms
```

`zig build release` produces `logsearch-x86_64-linux`, `logsearch-aarch64-linux`
and `logsearch-x86_64-windows.exe` in `zig-out/bin`. For a single platform, use
the standard Zig target option:

```sh
zig build -Doptimize=fast -Dtarget=aarch64-linux
```

The `native` and `release` steps build and run [UPX](https://upx.github.io/)
from source through the `zupx` dependency, so no external UPX installation is
required.

## Usage

```
usage: logsearch [OPTIONS] logfile [logfile2]...

OPTIONS:
    --help               print this help screen
    --version            print version and license
    --show-manual        show the manual (README) in a pager

  filtering:
    --level,-l <LEVEL>   only show entries with level equal to <LEVEL>
                         (brackets are optional)
    --class,-c <CLASS>   only show entries with the given class/logger name
    --search,-s <REGEX>  only show entries whose message matches <REGEX>
    --start <DATETIME>   only show entries at or after <DATETIME>
    --end <DATETIME>     only show entries at or before <DATETIME>

  --level, --class and --search can each be used multiple times.
  Within one option, any value may match (OR). Across options, one value
  of each given option must match (AND).

  --start/--end accept YYYY-MM, YYYY-MM-DD, or YYYY-MM-DD HH[:MM[:SS]].
  A T may separate date and time; an optional ,mmm or .mmm is accepted.
  Both bounds are inclusive; quote values containing spaces.
  Files ending in YYYY-MM-DD are skipped when that day is outside the range.

  logPattern:
    --timePattern <pattern>  default ^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d,\d\d\d
    --levelPattern <pattern> default \[[A-Za-z]+\]
    --classPattern <pattern> default [^ ]+
    --patternOrder <pattern> the order of the three patterns, default tlc
                             (time, then level, then class)

  output:
    --outputLines        print a separator line after each log entry
```

Positional arguments are one or more logfiles, which are processed in the order given.

### Manual

`--show-manual` displays this README, which is embedded into the binary, so no
installation files are needed. If standard output is a terminal, LogSearch uses the
first available pager from this list:

1. `mdcat` or `mdless` (renders markdown and pages)
2. `glow` (renders markdown)
3. `bat` or `batcat` (markdown syntax highlighting and paging)
4. `less`
5. `more`

If none of them is available, or if standard output is redirected, the manual is
written directly to stdout.

### Filtering

`--level`, `--class` and `--search` can each be given multiple times:

- Within one option, entries matching **any** of the given values are shown (OR).
- Across options, an entry must match **at least one value of each given option** (AND).

If an option is not given at all, it does not restrict the output.

Level and class values are compared literally against the captured text. With the default
patterns, the captured level includes the brackets (`[ERROR]`), but the brackets may be
omitted when filtering, so `-l ERROR` and `-l "[ERROR]"` are equivalent. The class is the
token directly following the level.

`--search` takes a regular expression that is matched against the message part only,
i.e. everything after the timestamp, level and class.

### Date and time ranges

`--start` and `--end` select entries by their timestamp. Both bounds are inclusive and
use the wall-clock time written in the log (no timezone conversion). A partial datetime
describes a whole period, so the start uses the first moment of that period and the end
uses the last:

| Value | `--start` means | `--end` means |
| --- | --- | --- |
| `2025-10` | 2025-10-01 00:00:00.000 | 2025-10-31 23:59:59.999 |
| `2025-10-08` | 2025-10-08 00:00:00.000 | 2025-10-08 23:59:59.999 |
| `2025-10-08 09` | 2025-10-08 09:00:00.000 | 2025-10-08 09:59:59.999 |
| `2025-10-08 09:30` | 2025-10-08 09:30:00.000 | 2025-10-08 09:30:59.999 |
| `2025-10-08 09:30:01` | 2025-10-08 09:30:01.000 | 2025-10-08 09:30:01.999 |

A `T` may be used between the date and time, and an optional fractional second
(`,mmm` or `.mmm`) is accepted. Values containing a space must be quoted.

If a filename ends in `YYYY-MM-DD` (for example `app.log.2025-10-19`), the file is skipped
without being opened when that entire day falls outside the requested range. Files
without a date suffix, such as the current `app.log`, are always read.

Range filtering uses the timestamp text captured by `--timePattern`. If a custom pattern
captures something that is not one of the formats above, LogSearch reports an error.

### Log patterns

By default LogSearch expects lines like this:

```
2024-01-01 12:00:01,000 [ERROR] com.example.Db connection failed
```

which corresponds to the pattern order `tlc` and the default patterns above. The three
patterns are joined with a single space in the given order. Use `--patternOrder` to
describe a different layout, for example `ltc` for:

```
[ERROR] 2024-01-01 12:00:01,000 com.example.Db connection failed
```

Custom regexes can be supplied with `--timePattern`, `--levelPattern` and
`--classPattern`; the classes and patterns just have to be consistent with the order in
which the parts appear on the line.

### Output

Every matching log entry is written to stdout as-is, including any continuation lines
that belong to it. With `--outputLines` a dashed separator is printed after each entry,
which makes the boundaries easier to see.

## Examples

Show all errors:

```sh
logsearch --level "[ERROR]" app.log
```

Show warnings and errors:

```sh
logsearch -l "[WARN]" -l "[ERROR]" app.log
```

Show errors from a specific class:

```sh
logsearch -l "[ERROR]" -c com.example.Db app.log
```

Search messages for a case-sensitive regular expression:

```sh
logsearch -s "connection (failed|refused)" app.log
```

Combine filters and search multiple files, with separators between entries:

```sh
logsearch -l "[ERROR]" -s "timeout" --outputLines app.log app.log.1
```

Show entries from October 2025:

```sh
logsearch --start 2025-10 --end 2025-10 logs/BlackMed.log.2025-10-*
```

Show a one-hour window:

```sh
logsearch --start "2025-10-19 09:00" --end "2025-10-19 10:00" logs/*
```

Use a custom layout where the level comes first:

```sh
logsearch --patternOrder ltc --timePattern '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d\d\d' app.log
```

## License

MIT, see [LICENSE.txt](LICENSE.txt).
