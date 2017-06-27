# QLS - Qore Language Server

QLS is a language server for the [Qore programming language](http://qore.org/).

QLS adheres to the [Language Server Protocol](https://github.com/Microsoft/language-server-protocol), specifically to [version 3.0](https://github.com/Microsoft/language-server-protocol/blob/master/protocol.md) of the protocol. All communication is done via stdin/stdout.

## Requirements

QLS requires [Qore](https://github.com/qorelanguage/qore) 0.8.13+ and the `astparser` module to be installed for all the functionality to work.

## Features

QLS supports the following LSP features:

- Hover info
- Goto definition
- Find references
- Document symbol search
- Workspace symbol search
- Syntax error reporting

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