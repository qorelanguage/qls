# QLS - Qore Language Server

QLS is a language server for the [Qore programming language](http://qore.org/).

QLS adheres to the [Language Server Protocol](https://github.com/Microsoft/language-server-protocol), specifically to [version 3.0](https://github.com/Microsoft/language-server-protocol/blob/master/protocol.md) of the protocol. All communication is done via stdin/stdout.

## Requirements

QLS requires [Qore](https://github.com/qorelanguage/qore) 0.8.13+ and the `astparser` and `json` modules to be installed for all the functionality to work.

`test/qls.qtest` requires `process` module for its run

## Features

QLS supports the following LSP features:

- Hover info
- Goto definition
- Find references
- Document symbol search
- Workspace symbol search
- Syntax error reporting

## Logging

If you want to log output of QLS, you can use the following configuration settings:

- `qore.logging` Boolean flag to set logging on or off. [default=false]
- `qore.logFile` String specifying QLS log file path. If logging is turned on, all the operations will be logged to this file. If not defined, `~/.qls.log` is used on Unix-like systems and `%AppData%\QLS\qls.log` on Windows.
- `qore.logVerbosity` Verbosity of QLS logging. From 0 to 2. [default=0]
- `qore.appendToLog` Boolean flag specifying whether to append to QLS log file or to overwrite it on each restart. [default=true]

## Supported LSP methods

QLS implements the following LSP methods:

### General methods

- `initialize`
- `initialized`
- `shutdown`
- `exit`

### Workspace methods
- `workspace/didChangeConfiguration`
- `workspace/didChangeWatchedFiles`
- `workspace/symbol`

### Document methods
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/willSave`
- `textDocument/didSave`
- `textDocument/didClose`
- `textDocument/hover`
- `textDocument/references`
- `textDocument/documentSymbol`
- `textDocument/definition`
