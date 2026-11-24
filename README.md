# Gargantua Mini Compiler

Gargantua is a small programming language and interpreter/compiler built with Flex and Bison. It includes its own lexer, parser, AST-based interpreter, data types, control flow, loops, functions, structs, pointers, built-in library functions, and file I/O.

## Features

- Integer, floating-point, character, string, boolean, and nil values
- Constants, variables, arrays, aliases, structs, and pointers
- Arithmetic, logical, bitwise, comparison, ternary, and type-cast operators
- `probe`/`reprobe`/`planb` conditionals and `wormhole` switch statements
- `orbit`, `drift`, `cycle`, `pulse`, and `sweep` loops
- Recursive missions (functions) and the `Endurance()` entry point
- Built-in math, string, and utility functions
- File read, write, and append operations
- Lexical, syntax, semantic, and runtime error reporting

## Project Files

- `gargantua.l` - Flex lexer that recognizes Gargantua keywords and tokens
- `gargantua.y` - Bison parser, AST definitions, symbol tables, and interpreter
- `input.txt` - Example Gargantua source program
- `mission_log.txt` - File I/O output created by the example program
- `output.txt` - Captured execution results from the example program

## Requirements

- Flex
- Bison
- GCC or another C compiler

## Build

From the project directory, run:

```powershell
bison -d gargantua.y
flex gargantua.l
gcc gargantua.tab.c lex.yy.c -o gargantua.exe -lm
```

## Run

Place the Gargantua source program in `input.txt`, then run:

```powershell
.\gargantua.exe
```

The program reads `input.txt` and writes results to `output.txt`. Console output confirms completion:

```text
Done. Check output.txt
```

## Example

The included `input.txt` demonstrates constants, operators, conditionals, loops, functions, structs, pointers, built-in libraries, and file I/O.

```gargantua
Endurance() launch
    send("Vessel: Endurance") !
land
```
