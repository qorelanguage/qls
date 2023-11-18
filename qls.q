#!/usr/bin/env qore
# -*- mode: qore; indent-tabs-mode: nil -*-

/*  qls.q Copyright 2017 - 2022 Qore Technologies, s.r.o.

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.
*/

#
# QLS - Language Server Protocol server implementation for Qore.
#

%require-types
%enable-all-warnings
%new-style
%strict-args

%requires qore >= 0.9.14

%requires json
%requires Mime
%requires Util

%requires ./qlib/Document.qm
%requires ./qlib/ErrorResponse.qm
%requires ./qlib/Files.qm
%requires ./qlib/Messenger.qm
%requires ./qlib/Notification.qm
%requires ./qlib/ParamValidator.qm
%requires ./qlib/SymbolInfoKinds.qm

%include ./qlib/ServerCapabilities.q

#! LSP FileChangeType definition
const FileChangeType = {
	"Created": 1,
	"Changed": 2,
	"Deleted": 3,
};

%exec-class QLS

class QLS {
    private {
        #! LSP header and content parts delimiter
        const LSP_PART_DELIMITER = "\r\n";

        #! MIN log level
        const LOGLEVEL_MIN = 0;

        #! MAX log level
        const LOGLEVEL_MAX = 2;

        #! Whether QLS has been initialized ("initialize" method called).
        bool initialized = False;

        #! Whether client is fully initialized ("initialized" method called).
        bool clientInitialized = False;

        #! Whether QLS has been shut down ("shutdown" method called).
        bool shutdown = False;

        # Whether the main loop should still run (or QLS should quit).
        bool running = True;

        # Exit code to use when quitting
        int exitCode = 0;

        #! PID of parent process
        int parentProcessId;

        #! JSON-RPC version string (ex. "2.0")
        string jsonRpcVer = "2.0";

        #! Workspace root URI (ex. "file:///home/user/projects/lorem").
        /** See Document::getFileUriPrefix()
            See Document::getFileUri()
         */
        string rootUri;

        #! Workspace root path (ex. "/home/user/projects/lorem")
        string rootPath;

        #! Client capabilities
        hash clientCapabilities;

        #! Client configuration
        hash clientConfig;

        #! Whether to log QLS operations.
        bool logging = PlatformOS != "Windows";

        #! Whether to append to the log file.
        bool appendToLog = True;

        #! Logging verbosity. Only messages with this level or lower will be logged.
        int logVerbosity = 0;

        #! Log file
        string logFile;

        #! Additional messages that need to be sent to VS Code.
        list messagesToSend = list();

        #! Map of JSON-RPC methods
        hash methodMap;

        #! Open text documents. Hash keys are document URIs.
        hash documents;

        #! Qore Documents in the current workspace
        hash workspaceDocs;

        #! Standard Qore modules
        hash stdModuleDocs;

        #! URIs of ignored documents
        hash ignoredUris;
    }

    private:internal {
        FileOutputStream fos;
    }

    constructor() {
        logFile = getDefaultLogFilePath();
        prepareLogFile(logFile);
        initMethodMap();
        set_return_value(main());
    }

    private:internal string getDefaultLogFilePath() {
        if (PlatformOS == "Windows") {
            return getenv("APPDATA") + DirSep + "QLS" + DirSep + "qls.log";
        } else {
            return getenv("HOME") + DirSep + ".qls.log";
        }
    }

    private:internal prepareLogFile(string logFilePath, bool force = False) {
        if (logging || force) {
            # prepare the log directory
            Dir d();
            if (!d.chdir(dirname(logFilePath))) {
                try {
                    d.create(0755);
                } catch (hash<ExceptionInfo> ex) {
                    return;
                }
            }

            # check if the log file can be opened and truncate it if appending is turned off
            try {
                fos = new FileOutputStream(logFile, appendToLog);
            } catch (hash<ExceptionInfo> ex) {
            }
        }
    }

    private:internal log(int verbosity, string fmt) {
        if (fos && verbosity <= logVerbosity) {
            string str = sprintf("%s: ", format_date("YYYY-MM-DD HH:mm:SS", now()));
            string msg = vsprintf(str + fmt + "\n", argv);
            fos.write(binary(msg));
        }
    }

    private:internal log(int verbosity, string fmt, softlist l) {
        if (fos && verbosity <= logVerbosity) {
            string str = sprintf("%s: ", format_date("YYYY-MM-DD HH:mm:SS", now()));
            string msg = vsprintf(str + fmt + "\n", l);
            fos.write(binary(msg));
        }
    }

    private:internal error(string fmt) {
        log(0, fmt, argv);
        stderr.vprintf("ERROR: " + fmt + "\n", argv);
        exit(1);
    }

    private:internal *string validateRequest(hash request) {
        if (!request.hasKey("jsonrpc")) {
            return ErrorResponse::invalidRequest(request, "Missing 'jsonrpc' attribute");
        }
        if (!request.hasKey("method")) {
            return ErrorResponse::invalidRequest(request, "Missing 'method' attribute");
        }
        return NOTHING;
    }

    private:internal initMethodMap() {
        methodMap = {
            # General methods
            "initialize": \meth_initialize(),
            "initialized": \meth_initialized(),
            "shutdown": \meth_shutdown(),
            "exit": \meth_exit(),
            "$/cancelRequest": \meth_cancelRequest(),

            # Workspace methods
            "workspace/didChangeConfiguration": \meth_ws_didChangeConfiguration(),
            "workspace/didChangeWatchedFiles": \meth_ws_didChangeWatchedFiles(),
            "workspace/symbol": \meth_ws_symbol(),

            # Document methods
            "textDocument/didOpen": \meth_td_didOpen(),
            "textDocument/didChange": \meth_td_didChange(),
            "textDocument/willSave": \meth_td_willSave(),
            "textDocument/willSaveWaitUntil": \meth_td_willSaveWaitUntil(),
            "textDocument/didSave": \meth_td_didSave(),
            "textDocument/didClose": \meth_td_didClose(),
            "textDocument/hover": \meth_td_hover(),
            "textDocument/references": \meth_td_references(),
            "textDocument/documentSymbol": \meth_td_documentSymbol(),
            "textDocument/definition": \meth_td_definition(),
        };
    }


    #=================
    # Main logic
    #=================

    testRun() {
        jsonRpcVer = "2.0";
        int id = 1;
        meth_initialize({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "initialize",
            "params": {
                "processId": 123,
                "rootPath": `pwd`,
                "capabilities": {}
            },
        });
        meth_initialized({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "initialized",
        });

        meth_ws_didChangeConfiguration({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "workspace/didChangeConfiguration",
            "params": {
                "settings": {
                    "qore": {
                        "executable": "/home/omusil/.qore/develop/bin/qore",
                        "useQLS": True,
                        "logging": False,
                        "logFile": NOTHING,
                        "logVerbosity": 0,
                        "appendToLog": False,
                        "debugAdapter": NOTHING,
                    }
                }
            },
        });

        string text;
        {
            ReadOnlyFile f("/home/omusil/random/qlstest/cip.q");
            text = f.read(1000000);
            f.close();
        }

        meth_td_didOpen({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": "file:///home/omusil/random/qlstest/dbgtest.q",
                    "languageId": "qore",
                    "version": 1,
                    "text": text
                }
            },
        });

        meth_td_documentSymbol({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "textDocument/documentSymbol",
            "params": {
                "textDocument": {
                    "uri": "file:///home/omusil/random/qlstest/dbgtest.q",
                }
            },
        });

        meth_td_hover({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "textDocument/hover",
            "params": {
                "textDocument": {
                    "uri": "file:///home/omusil/random/qlstest/dbgtest.q",
                },
                "position": {
                    "line": 14,
                    "character": 12,
                }
            },
        });

        meth_td_hover({
            "jsonrpc": jsonRpcVer,
            "id": id++,
            "method": "textDocument/hover",
            "params": {
                "textDocument": {
                    "uri": "file:///home/omusil/random/qlstest/dbgtest.q",
                },
                "position": {
                    "line": 20,
                    "character": 11,
                }
            },
        });

        meth_shutdown({
            "jsonrpc": jsonRpcVer,
            "id": id++,
        });

        meth_exit({
            "jsonrpc": jsonRpcVer,
            "id": id++,
        });
    }

    int main() {
        #testRun();
        #return 0;

        while (running) {
            # read JSON-RPC request
            hash received = Messenger::receive();
            list responses;
            if (received.error) {
                responses = (ErrorResponse::internalError(jsonRpcVer, received.error),);
            } else if (!received.msg) {
                responses = (ErrorResponse::internalError(jsonRpcVer, "no message received"),);
            } else {
                #log(0, "recv: %N", received.msg);
                responses = handleRequest(received.msg);
            }

            # send back response if any
            #log(0, "resp: %N", response);
            if (responses) {
                map Messenger::send($1), responses, $1.typeCode() == NT_STRING;
            }

            # send additional messages
            if (initialized && clientInitialized) {
                while (messagesToSend.size()) {
                    list msg = extract messagesToSend, 0, 1;
                    foreach auto m in (msg)
                        Messenger::send(m);
                }
            }
        }

        return exitCode;
    }

    softlist handleRequest(string msg) {
        # parse the request
        any request = parse_json(msg);
        #stderr.printf("req: %N\n", request);

        # validate request
        if (request.typeCode() != NT_HASH) {
            return ErrorResponse::invalidRequest({"received": msg, "jsonrpc": jsonRpcVer},
                "Invalid JSON-RPC request");
        }

        *string validation = validateRequest(request);
        if (validation) {
            return validation;
        }

        # check that QLS has been initialized
        if (!initialized && request.method != "initialize") {
            return ErrorResponse::notInitialized(request);
        }

        # check that the method exists
        if (!methodMap.hasKey(request.method)) {
            if (request.id) {
                return ErrorResponse::methodNotFound(request);
            } else { # it's notification -> ignore
                return NOTHING;
            }
        }

        # call appropriate method
        softlist responses = methodMap{request.method}(request);
        return responses;
    }


    #=================
    # Parsing
    #=================

    private:internal parseFilesInWorkspace() {
        if (!rootPath) {
            log(0, "WARNING: root path not set - workspace files will not be parsed");
            return;
        }

        # find all Qore files in the workspace
        list qoreFiles;
        try {
            qoreFiles = Files::find_qore_files(rootPath);
        } catch (hash<ExceptionInfo> ex) {
            if (ex.err == "DIR-READ-FAILURE") {
                log(0, "WARNING: root path scanning failed: %s", get_exception_string(ex));
                push messagesToSend, Notification::showMessage(
                    jsonRpcVer,
                    MessageType.Warning,
                    "An error happened during reading of workspace root, therefore Qore IntelliSense features might "
                        "not work fully. "
                        "Please check that the workspace does not contain any invalid symlinks or other invalid "
                        "files or directories.");
                return;
            }
            if (ex.err == "WORKSPACE-PATH-ERROR") {
                log(0, "WARNING: error processing root path: %s", get_exception_string(ex));
                push messagesToSend, Notification::showMessage(
                    jsonRpcVer,
                    MessageType.Warning,
                    "Could not open workspace root. Some Qore IntelliSense features might not work fully. "
                        "Please check that the workspace does not contain any invalid symlinks or other invalid "
                        "files or directories.");
                return;
            }
        }

        # create a list of file URIs
        int rootPathSize = rootPath.size();
        qoreFiles = map rootUri + $1.substr(rootPathSize), qoreFiles;
        log(1, "qore files in workspace: %N", qoreFiles);

        # measure start time
        date start = now_us();

        # parse everything
        map workspaceDocs{$1} = new Document($1), qoreFiles;

        # measure end time
        date end = now_us();
        log(0, "parsing of %d workspace files took: %y", qoreFiles.size(), end-start);
    }

    private:internal parseStdModules() {
        # find standard Qore modules
        list moduleFiles;
        try {
            moduleFiles = Files::find_std_modules();
        } catch (hash<ExceptionInfo> ex) {
            if (ex.err == "DIR-READ-FAILURE") {
                log(0, "WARNING: std module scanning failed - %s: %s", ex.err, ex.desc);
                push messagesToSend, Notification::showMessage(
                    jsonRpcVer,
                    MessageType.Warning,
                    "An error happened during reading of standard Qore module files, therefore Qore IntelliSense features might not work fully.");
                return;
            }
            rethrow;
        }

        # create a list of file URIs
        moduleFiles = map Document::getFileUri($1), moduleFiles;

        # parse everything
        map stdModuleDocs{$1} = new Document($1), moduleFiles;
    }


    #=================
    # General methods
    #=================

    #! "initialize" method handler
    private *string meth_initialize(hash request) {
        log(0, "initialize request received: %N", request);
        jsonRpcVer = request.jsonrpc;

        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        if (request.params.typeCode() != NT_HASH) {
            return ErrorResponse::invalidRequest(
                request,
                sprintf(
                    "required attribute 'params' has invalid type: %s",
                    request.params.type()
                )
            );
        }
        *string validation = ParamValidator::initializeParams(request, request.params);
        if (validation) {
            return validation;
        }

        # parse/save initialization params
        parentProcessId = request.params.processId;
        clientCapabilities = request.params.capabilities;
        if (request.params.rootUri) {
            rootUri = request.params.rootUri;
        }
        if (request.params.rootPath) {
            rootPath = request.params.rootPath;
        }
        if (!rootPath && rootUri) {
            rootPath = parse_url(rootUri).path;
        }
        if (!rootUri && rootPath) {
            rootUri = Document::getFileUri(rootPath);
        }

        try {
            # parse all Qore files in the current workspace
            parseFilesInWorkspace();
        } catch (hash<ExceptionInfo> ex) {
            return ErrorResponse::invalidParams(request, sprintf("%s: %s: %N", ex.err, ex.desc, ex));
        }

        try {
            # parse standard Qore modules
            parseStdModules();
        } catch (hash<ExceptionInfo> ex) {
            return ErrorResponse::internalError(jsonRpcVer, sprintf("%s: %s: %N", ex.err, ex.desc, ex));
        }

        # create response
        hash result = {
            "capabilities": ServerCapabilities
        };

        log(0, "initialization complete!");

        initialized = True;
        return make_jsonrpc_response(jsonRpcVer, request.id, result);
    }

    #! "initialized" notification method handler
    private *string meth_initialized(hash request) {
        clientInitialized = True;
        log(0, "client initialized!");
        return NOTHING;
    }

    #! "shutdown" method handler
    private *string meth_shutdown(hash request) {
        shutdown = True;
        log(0, "shutdown request received");
        return make_jsonrpc_response(jsonRpcVer, request.id, {});
    }

    #! "exit" notification method handler
    private *string meth_exit(hash request) {
        log(0, "exit request received");
        if (!shutdown) {
            exitCode = 1;
        }
        log(0, "exitCode: %d", exitCode);
        running = False;
        return NOTHING;
    }

    #! "$/cancelRequest" notification method handler
    private *string meth_cancelRequest(hash request) {
        # ignore for now
        return NOTHING;
    }


    #===================
    # Workspace methods
    #===================

    #! "workspace/didChangeConfiguration" notification method handler
    private *string meth_ws_didChangeConfiguration(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::didChangeConfigParams(request, request.params);
        if (validation) {
            return validation;
        }

        clientConfig = request.params.settings;
        log(0, "changed configuration received: %N", clientConfig);

        logging = clientConfig.qore.logging ?? False;
        appendToLog = clientConfig.qore.appendToLog ?? True;
        logVerbosity = clientConfig.qore.logVerbosity ?? 0;
        logVerbosity = (logVerbosity < LOGLEVEL_MIN) ? LOGLEVEL_MIN : ((logVerbosity > LOGLEVEL_MAX) ? LOGLEVEL_MAX : logVerbosity);

        if ((clientConfig.qore.logFile != NOTHING) &&
            (clientConfig.qore.logFile.typeCode() == NT_STRING)) {
            logFile = clientConfig.qore.logFile;
        } else {
            logFile = getDefaultLogFilePath();
        }
        prepareLogFile(logFile);

        if (logging && !fos)
            return Notification::showMessage(jsonRpcVer, MessageType.Warning,
                "QLS log file could not be opened. Logging will be turned off.");
        return NOTHING;
    }

    #! "workspace/didChangeWatchedFiles" notification method handler
    private *string meth_ws_didChangeWatchedFiles(hash request) { # TODO add validation
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::didChangeWatchedFilesParams(request, request.params);
        if (validation) {
            return validation;
        }

        # handle changes
        list changes = request.params.changes;
        foreach hash change in (changes) {
            switch (change.type) {
                case FileChangeType.Created:
                case FileChangeType.Changed:
                    workspaceDocs{change.uri} = new Document(change.uri);
                case FileChangeType.Deleted:
                    remove workspaceDocs{change.uri};
                default:
                    break;
            }
        }
        return NOTHING;
    }

    #! "workspace/symbol" method handler
    private *string meth_ws_symbol(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::workspaceSymbolParams(request, request.params);
        if (validation) {
            return validation;
        }

        # get the search query
        string query = request.params.query;
        log(1, "workspace symbols requested; query: '%s'", query);

        # find matching symbols
        list symbols = ();
        map symbols += $1.findMatchingSymbols(query), documents.iterator();
        map symbols += $1.findMatchingSymbols(query), workspaceDocs.iterator();
        log(1, "found %d workspace symbols for query: '%s'", symbols.size(), query);

        return make_jsonrpc_response(jsonRpcVer, request.id, symbols);
    }


    #==================
    # Document methods
    #==================

    #! "textDocument/didOpen" notification method handler
    private softlist meth_td_didOpen(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didOpen' request missing required attribute 'params'");
            return NOTHING;
        }

        # extract params hashes
        list paramsList;
        if (request.params.typeCode() == NT_LIST) {
            foreach any p in (request.params) {
                if (p) {
                    paramsList += p;
                }
            }
        } else if (request.params.typeCode() == NT_HASH) {
            paramsList += request.params;
        } else {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is not an array or object");
        }

        # go through the params hashes
        list responses;
        foreach hash params in (paramsList) {
            *string validation = ParamValidator::textDocumentItem(request, params);
            if (validation) {
                log(1, "'textDocument/didOpen' request failed validation: " + validation);
                continue;
            }

            reference textDoc = \params.textDocument;
            *Document doc;
            if (workspaceDocs{textDoc.uri}) {
                doc = remove workspaceDocs{textDoc.uri};
            } else {
                # ignore non-local files
                if (textDoc.uri =~ /^file:\//) {
                    doc = new Document(textDoc.uri, textDoc.text, textDoc.languageId, textDoc.version);
                } else {
                    ignoredUris{textDoc.uri} = True;
                    log(1, "added URI to ignored: '%s'", textDoc.uri);
                }
            }
            if (doc != NOTHING) {
                documents{textDoc.uri} = doc;
                log(1, "opened text document: '%s'", textDoc.uri);

                if (doc.getParseErrorCount() > 0) {
                    *list diagnostics = doc.getDiagnostics();
                    responses += Notification::diagnostics(jsonRpcVer, textDoc.uri, diagnostics);
                    continue;
                }
            }

            responses += Notification::diagnostics(jsonRpcVer, textDoc.uri);
        }
        return responses;
    }

    #! "textDocument/didChange" notification method handler
    private *string meth_td_didChange(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didChange' request missing required attribute 'params'");
            return NOTHING;
        }
        *string validation = ParamValidator::versionedTextDocumentIdentifier(request, request.params);
        if (validation) {
            log(1, "'textDocument/didChange' request failed validation: " + validation);
            return NOTHING;
        }

        # handle changes
        hash textDoc = request.params.textDocument;
        if (ignoredUris{textDoc.uri}) {
            log(2, sprintf("'textDocument/didChange' request for ignored URI '%s'", textDoc.uri));
            return NOTHING;
        }
        if (!exists documents{textDoc.uri}) {
            log(1, sprintf("'textDocument/didChange' request attempted to change non-existent or not opened document '%s'",
                textDoc.uri));
            return NOTHING;
        }

        reference doc = \documents{textDoc.uri};
        foreach hash change in (request.params.contentChanges) {
            doc.didChange(change);
        }
        doc.changeVersion(textDoc.version);
        log(1, "text document changed: '%s'", textDoc.uri);

        if (doc.getParseErrorCount() > 0) {
            *list diagnostics = doc.getDiagnostics();
            return Notification::diagnostics(jsonRpcVer, textDoc.uri, diagnostics);
        }
        return Notification::diagnostics(jsonRpcVer, textDoc.uri);
    }

    #! "textDocument/willSave" notification method handler
    private *string meth_td_willSave(hash request) {
        # ignore for now
        return NOTHING;
    }

    #! "textDocument/willSaveWaitUntil" method handler
    private *string meth_td_willSaveWaitUntil(hash request) {
        return ErrorResponse::invalidRequest(request);
    }

    #! "textDocument/didSave" notification method handler
    private *string meth_td_didSave(hash request) {
        # ignore for now
        return NOTHING;
    }

    #! "textDocument/didClose" notification method handler
    private *string meth_td_didClose(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didClose' request missing required attribute 'params'");
            return NOTHING;
        }
        *string validation = ParamValidator::textDocumentIdentifier(request, request.params);
        if (validation) {
            log(1, "'textDocument/didClose' request failed validation: " + validation);
            return NOTHING;
        }

        if (ignoredUris{request.params.textDocument.uri}) {
            log(2, sprintf("'textDocument/didClose' request for ignored URI '%s'",
                request.params.textDocument.uri));
            return NOTHING;
        }

        if (!exists documents{request.params.textDocument.uri}) {
            log(1, sprintf("'textDocument/didClose' request attempted to close non-existent or not opened document '%s'",
                request.params.textDocument.uri));
            return NOTHING;
        }

        string uri = request.params.textDocument.uri;
        workspaceDocs{uri} = remove documents{uri};
        log(1, "closed text document: '%s'", uri);
        return NOTHING;
    }

    #! "textDocument/hover" method handler
    private *string meth_td_hover(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::textDocumentPositionParams(request, request.params);
        if (validation) {
            return validation;
        }

        if (ignoredUris{request.params.textDocument.uri}) {
            log(2, sprintf("'textDocument/hover' request for ignored URI '%s'",
                request.params.textDocument.uri));
            return make_jsonrpc_response(jsonRpcVer, request.id, {});
        }

        if (!exists documents{request.params.textDocument.uri}) {
            return ErrorResponse::nonExistentDocument(request);
        }

        # get the document
        Document doc = documents{request.params.textDocument.uri};

        # find requested symbol in the document
        *hash symbolInfo = doc.findSymbolInfo(request.params.position);
        #stderr.printf("si: %N\n", symbolInfo);
        if (!symbolInfo) {
            return make_jsonrpc_response(jsonRpcVer, request.id, doc.hover(request.params.position));
        }

        # prepare search query
        string query = symbolInfo.name;
        {
            int lastDoubleColon = query.rfind("::");
            if (lastDoubleColon != -1)
                query = query.substr(lastDoubleColon+2);
            if (query.equalPartial("*"))
                query = query.substr(1);
        }

        # find matching symbols
        list symbols = ();
        map symbols += $1.findMatchingSymbols(query, True), documents.iterator();
        map symbols += $1.findMatchingSymbols(query, True), workspaceDocs.iterator();
        map symbols += $1.findMatchingSymbols(query, True), stdModuleDocs.iterator();
        #stderr.printf("symbols: %N\n", symbols);

        for (int i = symbols.size()-1; i > 0; i--) {
            if (SymbolUsageFastMap{string(symbolInfo.usage)}) {
                if (!SymbolUsageFastMap{string(symbolInfo.usage)}.contains(symbols[i].kind))
                    splice symbols, i, 1;
            }
        }
        #stderr.printf("after: %N\n", symbols);

        # prepare results
        hash result = { "range": symbolInfo.range, "contents": list() };
        foreach hash symbol in (symbols) {
            *hash description;
            if (documents{symbol.location.uri})
                description = documents{symbol.location.uri}.hoverInfo(symbol.kind, symbol.location.range.start);
            else if (workspaceDocs{symbol.location.uri})
                description = workspaceDocs{symbol.location.uri}.hoverInfo(symbol.kind, symbol.location.range.start);
            else if (stdModuleDocs{symbol.location.uri})
                description = stdModuleDocs{symbol.location.uri}.hoverInfo(symbol.kind, symbol.location.range.start);

            if (description) {
                result.contents += replace(description.description, "*", "\\*");;
            }
        }

        return make_jsonrpc_response(jsonRpcVer, request.id, result);
    }

    #! "textDocument/references" method handler
    private *string meth_td_references(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::referenceParams(request, request.params);
        if (validation) {
            return validation;
        }

        if (ignoredUris{request.params.textDocument.uri}) {
            log(2, sprintf("'textDocument/references' request for ignored URI '%s'",
                request.params.textDocument.uri));
            return make_jsonrpc_response(jsonRpcVer, request.id, list());
        }

        if (!exists documents{request.params.textDocument.uri}) {
            return ErrorResponse::nonExistentDocument(request);
        }

        # find references
        Document doc = documents{request.params.textDocument.uri};
        *list references = doc.findReferences(request.params.position, request.params.context.includeDeclaration);
        return make_jsonrpc_response(jsonRpcVer, request.id, references ?? list());
    }

    #! "textDocument/documentSymbol" method handler
    private softlist meth_td_documentSymbol(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }

        # extract params hashes from the params key
        list paramsList;
        if (request.params.typeCode() == NT_LIST) {
            foreach any p in (request.params) {
                if (p && p.typeCode() == NT_HASH) {
                    paramsList += p;
                }
            }
        } else if (request.params.typeCode() == NT_HASH) {
            paramsList += request.params;
        } else {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is not an array or object");
        }

        # go through the params hashes
        list responses;
        foreach hash params in (paramsList) {
            *string validation = ParamValidator::textDocumentIdentifier(request, params);
            if (validation) {
                #stderr.printf("ds req: %N\nparamsList: %N\nparams: %N\nvalidation: %N\n", request, paramsList, params, validation);
                #throw "VALIDATION-FAIL";
                return validation;
            }

            if (ignoredUris{params.textDocument.uri}) {
                log(2, sprintf("'textDocument/documentSymbol' request for ignored URI '%s'",
                    params.textDocument.uri));
                responses += make_jsonrpc_response(jsonRpcVer, request.id, list());
                continue;
            }

            if (!exists documents{params.textDocument.uri}) {
                responses += ErrorResponse::nonExistentDocument(request);
                continue;
            }

            # find document symbols
            Document doc = documents{params.textDocument.uri};

            *list ret;
            switch (params.retType) {
                case 'node_info':
                    ret = doc.getNodesInfo();
                    break;
                default:
                    ret = doc.findSymbols();
            }
            responses += make_jsonrpc_response(jsonRpcVer, request.id, ret ?? list());
            continue;
        }
        return responses;
    }

    #! "textDocument/definition" method handler
    private *string meth_td_definition(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");
        }
        *string validation = ParamValidator::textDocumentPositionParams(request, request.params);
        if (validation) {
            return validation;
        }

        if (ignoredUris{request.params.textDocument.uri}) {
            log(2, sprintf("'textDocument/definition' request for ignored URI '%s'",
                request.params.textDocument.uri));
            return make_jsonrpc_response(jsonRpcVer, request.id, list());
        }

        if (!exists documents{request.params.textDocument.uri}) {
            return ErrorResponse::nonExistentDocument(request);
        }

        # get the document
        Document doc = documents{request.params.textDocument.uri};

        # find requested symbol in the document
        *hash symbolInfo = doc.findSymbolInfo(request.params.position);
        if (!symbolInfo) {
            return make_jsonrpc_response(jsonRpcVer, request.id, list());
        }

        # prepare search query
        string query = symbolInfo.name;
        {
            int lastDoubleColon = query.rfind("::");
            if (lastDoubleColon != -1)
                query = query.substr(lastDoubleColon+2);
            if (query.equalPartial("*"))
                query = query.substr(1);
        }

        # find matching symbols
        list symbols = ();
        map symbols += $1.findMatchingSymbols(query, True), documents.iterator();
        map symbols += $1.findMatchingSymbols(query, True), workspaceDocs.iterator();
        map symbols += $1.findMatchingSymbols(query, True), stdModuleDocs.iterator();

        for (int i = symbols.size()-1; i > 0; i--) {
            if (SymbolUsageFastMap{string(symbolInfo.usage)}) {
                if (!SymbolUsageFastMap{string(symbolInfo.usage)}.contains(symbols[i].kind))
                    splice symbols, i, 1;
            }
        }

        # prepare results
        list result = map $1.location, symbols;
        return make_jsonrpc_response(jsonRpcVer, request.id, result);
    }
}
