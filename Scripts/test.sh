#!/bin/sh
# Runs the tests. Swift Testing ships with the Command Line Tools but is not on the
# default search path without Xcode, so point the compiler and linker at it.
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test "$@" -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F \
  -Xlinker -L$L -Xlinker -rpath -Xlinker $L
