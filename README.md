# LogSearch
a small commandline tool to read (java) logfiles and filter them

## Usage
```
usage: logsearch [OPTIIONS] logfile [logfile2]...

OPTIIONS:
    --help               print this help screen
    --version            print version and license

  filtering:
    --level,-l <LEVEL>   only show level equal to <LEVEL>
    --class,-c <CLASS>   only show matching <CLASS>
    --search,-s <REGEX>  search for log messages matching <REGEX>

  --level,--calss and --search can be used multiple times
  a line matching any of the given levels,classes or searches will be outputed
  one of each (level, class and search) has to match for the line to be outputed

  logPattern:
    --timePattern <pattern>  default ^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d,\d\d\d
    --levelPattern <pattern> default \[[A-Za-z]+\]  
    --classPattern <pattern> default [^ ]+
    --patternOrder <pattern> the order of the 3 patterns default tlc
                             i.e. time then level then class

  output:
    --outputLines  outputs lines between each log entry (default not set)
```
