#!/usr/bin/env qore
# -*- mode: qore; indent-tabs-mode: nil -*-

/*  qls.q Copyright 2017 Qore Technologies, s.r.o.

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

%requires qore >= 0.8.12

%requires json
%requires Mime

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

        #! Workspace root URI (ex. "file:///home/user/projects/lorem")
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

        #! Whether the log file can be opened.
        bool canOpenLog = False;

        #! Logging verbosity. Only messages with this level or lower will be logged.
        int logVerbosity = 0;

        #! Log file
        string logFile;

        #! Map of JSON-RPC methods
        hash methodMap;

        #! Open text documents. Hash keys are document URIs.
        hash documents;

        #! Qore Documents in the current workspace
        hash workspaceDocs;

        #! Standard Qore modules
        hash stdModuleDocs;
    }

    constructor() {
        logFile = getDefaultLogFilePath();
        prepareLogFile(logFile);
        initMethodMap();
        set_return_value(main());
    }

    private:internal string getDefaultLogFilePath() {
        if (PlatformOS == "Windows")
            return getenv("APPDATA") + DirSep + "QLS" + DirSep + "qls.log";
        else
            return getenv("HOME") + DirSep + ".qls.log";
    }

    private:internal prepareLogFile(string logFilePath, bool force = False) {
        if (logging || force) {
            # prepare the log directory
            Dir d();
            if (!d.chdir(dirname(logFilePath))) {
                try {
                    d.create(0755);
                }
                catch (e) {
                    canOpenLog = False;
                    return;
                }
            }

            # check if the log file can be opened and truncate it if appending is turned off
            try {
                FileOutputStream fos(logFile, appendToLog);
                fos.close();
                canOpenLog = True;
            }
            catch (e) {
                canOpenLog = False;
            }
        }
    }

    private:internal log(int verbosity, string fmt) {
        if (logging && canOpenLog && verbosity <= logVerbosity) {
            string str = sprintf("%s: ", format_date("YYYY-MM-DD HH:mm:SS", now()));
            string msg = vsprintf(str + fmt + "\n", argv);
            FileOutputStream fos(logFile, True);
            fos.write(binary(msg));
            fos.close();
        }
    }

    private:internal log(int verbosity, string fmt, softlist l) {
        if (logging && canOpenLog && verbosity <= logVerbosity) {
            string str = sprintf("%s: ", format_date("YYYY-MM-DD HH:mm:SS", now()));
            string msg = vsprintf(str + fmt + "\n", l);
            FileOutputStream fos(logFile, True);
            fos.write(binary(msg));
            fos.close();
        }
    }

    private:internal error(string fmt) {
        log(0, fmt, argv);
        stderr.vprintf("ERROR: " + fmt + "\n", argv);
        exit(1);
    }

    private:internal *string validateRequest(hash request) {
        if (!request.hasKey("jsonrpc"))
            return ErrorResponse::invalidRequest(request, "Missing 'jsonrpc' attribute");
        if (!request.hasKey("method"))
            return ErrorResponse::invalidRequest(request, "Missing 'method' attribute");
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
            "workspace/executeCommand": \meth_ws_executeCommand(),

            # Document methods
            "textDocument/didOpen": \meth_td_didOpen(),
            "textDocument/didChange": \meth_td_didChange(),
            "textDocument/willSave": \meth_td_willSave(),
            "textDocument/willSaveWaitUntil": \meth_td_willSaveWaitUntil(),
            "textDocument/didSave": \meth_td_didSave(),
            "textDocument/didClose": \meth_td_didClose(),
            "textDocument/completion": \meth_td_completion(),
            "completionItem/resolve": \meth_completionItem_resolve(),
            "textDocument/hover": \meth_td_hover(),
            "textDocument/signatureHelp": \meth_td_signatureHelp(),
            "textDocument/references": \meth_td_references(),
            "textDocument/documentHighlight": \meth_td_documentHighlight(),
            "textDocument/documentSymbol": \meth_td_documentSymbol(),
            "textDocument/formatting": \meth_td_formatting(),
            "textDocument/rangeFormatting": \meth_td_rangeFormatting(),
            "textDocument/onTypeFormatting": \meth_td_onTypeFormatting(),
            "textDocument/definition": \meth_td_definition(),
            "textDocument/codeAction": \meth_td_codeAction(),
            "textDocument/codeLens": \meth_td_codeLens(),
            "codeLens/resolve": \meth_codeLens_resolve(),
            "textDocument/documentLink": \meth_td_documentLink(),
            "documentLink/resolve": \meth_documentLink_resolve(),
            "textDocument/rename": \meth_td_rename(),
        };
    }


    #=================
    # Main logic
    #=================

    int main() {
        while (running) {
            # read JSON-RPC request
            hash received = Messenger::receive();
            *string response;
            if (received.error) {
                response = ErrorResponse::internalError(jsonRpcVer, received.error);
            }
            else if (!received.msg) {
                response = ErrorResponse::internalError(jsonRpcVer, "no message received");
            }
            else {
                response = handleRequest(received.msg);
            }

            # send back response if any
            if (response)
                Messenger::send(response);
        }

        return exitCode;
    }

    *string handleRequest(string msg) {
        # parse the request
        any request = parse_json(msg);

        # validate request
        if (request.typeCode() != NT_HASH)
            return ErrorResponse::invalidRequest({"received": msg, "jsonrpc": jsonRpcVer}, "Invalid JSON-RPC request");

        *string validation = validateRequest(request);
        if (validation)
            return validation;

        # check that QLS has been initialized
        if (!initialized && request.method != "initialize")
            return ErrorResponse::notInitialized(request);

        # check that the method exists
        if (!methodMap.hasKey(request.method)) {
            if (request.id)
                return ErrorResponse::methodNotFound(request);
            else # it's notification -> ignore
                return NOTHING;
        }

        # call appropriate method
        *string response = methodMap{request.method}(request);
        return response;
    }


    #=================
    # Parsing
    #=================

    private:internal parseFilesInWorkspace() {
        if (!rootPath) {
            log(0, "WARNING: root path not set - workspace files will not be parsed\n");
            return;
        }

        # find all Qore files in the workspace
        list qoreFiles = Files::find_qore_files(rootPath);

        # create a list of file URIs
        int rootPathSize = rootPath.size();
        qoreFiles = map rootUri + $1.substr(rootPathSize), qoreFiles;
        log(1, "qore files in workspace: %N\n", qoreFiles);

        # measure start time
        date start = now_us();

        # parse everything
        map workspaceDocs{$1} = new Document($1), qoreFiles;

        # measure end time
        date end = now_us();
        log(0, "parsing of %d workspace files took: %y\n", qoreFiles.size(), end-start);
    }

    private:internal parseStdModules() {
        # find standard Qore modules
        list moduleFiles = Files::find_std_modules();

        # create a list of file URIs
        moduleFiles = map "file://" + $1, moduleFiles;

        # parse everything
        map stdModuleDocs{$1} = new Document($1), moduleFiles;
    }


    #=================
    # General methods
    #=================

    #! "initialize" method handler
    private:internal *string meth_initialize(hash request) {
        log(0, "initialize request received: %N", request);
        jsonRpcVer = request.jsonrpc;

        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::initializeParams(request);
        if (validation)
            return validation;

        # parse/save initialization params
        parentProcessId = request.params.processId;
        clientCapabilities = request.params.capabilities;
        if (request.params{"rootUri"})
            rootUri = request.params.rootUri;
        if (request.params{"rootPath"})
            rootPath = request.params.rootPath;
        if (!rootPath && rootUri)
            rootPath = parse_url(rootUri).path;
        if (!rootUri && rootPath)
            rootUri = "file://" + rootPath;

        try {
            # parse all Qore files in the current workspace
            parseFilesInWorkspace();
        }
        catch (hash ex) {
            return ErrorResponse::invalidParams(request, sprintf("%s: %s: %N", ex.err, ex.desc, ex));
        }

        try {
            # parse standard Qore modules
            parseStdModules();
        }
        catch (hash ex) {
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
    private:internal *string meth_initialized(hash request) {
        clientInitialized = True;
        log(0, "client initialized!");
        return NOTHING;
    }

    #! "shutdown" method handler
    private:internal *string meth_shutdown(hash request) {
        shutdown = True;
        log(0, "shutdown request received");
        return make_jsonrpc_response(jsonRpcVer, request.id, {});
    }

    #! "exit" notification method handler
    private:internal *string meth_exit(hash request) {
        log(0, "exit request received");
        if (!shutdown)
            exitCode = 1;
        log(0, "exitCode: %d", exitCode);
        running = False;
        return NOTHING;
    }

    #! "$/cancelRequest" notification method handler
    private:internal *string meth_cancelRequest(hash request) {
        # ignore for now
        return NOTHING;
    }


    #===================
    # Workspace methods
    #===================

    #! "workspace/didChangeConfiguration" notification method handler
    private:internal *string meth_ws_didChangeConfiguration(hash request) {
        clientConfig = request.params.settings;
        log(0, "changed configuration received: %N", clientConfig);

        logging = clientConfig.qore.logging ?? False;
        appendToLog = clientConfig.qore.appendToLog ?? True;
        logVerbosity = clientConfig.qore.logVerbosity ?? 0;
        logVerbosity = (logVerbosity < LOGLEVEL_MIN) ? LOGLEVEL_MIN : ((logVerbosity > LOGLEVEL_MAX) ? LOGLEVEL_MAX : logVerbosity);

        if (clientConfig.qore.logFile)
            logFile = clientConfig.qore.logFile;
        else
            logFile = getDefaultLogFilePath();
        prepareLogFile(logFile);

        if (logging && !canOpenLog)
            return Notification::showMessage(jsonRpcVer, MessageType.Warning,
                "QLS log file could not be opened. Logging will be turned off.");
        return NOTHING;
    }

    #! "workspace/didChangeWatchedFiles" notification method handler
    private:internal *string meth_ws_didChangeWatchedFiles(hash request) {
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
    private:internal *string meth_ws_symbol(hash request) {
        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::workspaceSymbolParams(request);
        if (validation)
            return validation;

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

    #! "workspace/executeCommand" method handler
    private:internal *string meth_ws_executeCommand(hash request) {
        return ErrorResponse::methodNotFound(request);
    }


    #==================
    # Document methods
    #==================

    #! "textDocument/didOpen" notification method handler
    private:internal *string meth_td_didOpen(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didOpen' request missing required attribute 'params'");
            return NOTHING;
        }

        *string validation = ParamValidator::textDocumentItem(request);
        if (validation) {
            log(1, "'textDocument/didOpen' request failed validation: " + validation);
            return NOTHING;
        }

        reference textDoc = \request.params.textDocument;
        *Document doc;
        if (workspaceDocs{textDoc.uri})
            doc = remove workspaceDocs{textDoc.uri};
        else
            doc = new Document(textDoc.uri, textDoc.text, textDoc.languageId, textDoc.version);
        documents{textDoc.uri} = doc;
        log(1, "opened text document: %s", textDoc.uri);

        if (doc.getParseErrorCount() > 0) {
            *list diagnostics = doc.getDiagnostics();
            return Notification::diagnostics(jsonRpcVer, textDoc.uri, diagnostics);
        }
        return Notification::diagnostics(jsonRpcVer, textDoc.uri);
    }

    #! "textDocument/didChange" notification method handler
    private:internal *string meth_td_didChange(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didChange' request missing required attribute 'params'");
            return NOTHING;
        }

        *string validation = ParamValidator::versionedTextDocumentIdentifier(request);
        if (validation) {
            log(1, "'textDocument/didChange' request failed validation: " + validation);
            return NOTHING;
        }

        hash textDoc = request.params.textDocument;
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
        log(1, "text document changed: %s", textDoc.uri);

        if (doc.getParseErrorCount() > 0) {
            *list diagnostics = doc.getDiagnostics();
            return Notification::diagnostics(jsonRpcVer, textDoc.uri, diagnostics);
        }
        return Notification::diagnostics(jsonRpcVer, textDoc.uri);
    }

    #! "textDocument/willSave" notification method handler
    private:internal *string meth_td_willSave(hash request) {
        # ignore for now
        return NOTHING;
    }

    #! "textDocument/willSaveWaitUntil" method handler
    private:internal *string meth_td_willSaveWaitUntil(hash request) {
        return ErrorResponse::invalidRequest(request);
    }

    #! "textDocument/didSave" notification method handler
    private:internal *string meth_td_didSave(hash request) {
        # ignore for now
        return NOTHING;
    }

    #! "textDocument/didClose" notification method handler
    private:internal *string meth_td_didClose(hash request) {
        # validate request
        if (!request.hasKey("params")) {
            log(1, "'textDocument/didClose' request missing required attribute 'params'");
            return NOTHING;
        }

        *string validation = ParamValidator::textDocumentIdentifier(request);
        if (validation) {
            log(1, "'textDocument/didClose' request failed validation: " + validation);
            return NOTHING;
        }

        if (!exists documents{request.params.textDocument.uri}) {
            log(1, sprintf("'textDocument/didClose' request attempted to close non-existent or not opened document '%s'",
                request.params.textDocument.uri));
            return NOTHING;
        }

        string uri = request.params.textDocument.uri;
        workspaceDocs{uri} = remove documents{uri};
        log(1, "closed text document: %s", uri);
        return NOTHING;
    }

    #! "textDocument/completion" method handler
    private:internal *string meth_td_completion(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "completionItem/resolve" method handler
    private:internal *string meth_completionItem_resolve(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/hover" method handler
    private:internal *string meth_td_hover(hash request) {
        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::textDocumentPositionParams(request);
        if (validation)
            return validation;

        if (!exists documents{request.params.textDocument.uri})
            return ErrorResponse::nonExistentDocument(request);

        # get the document
        Document doc = documents{request.params.textDocument.uri};

        # find requested symbol in the document
        *hash symbolInfo = doc.findSymbolInfo(request.params.position);
        #stderr.printf("si: %N\n", symbolInfo);
        if (!symbolInfo)
            return make_jsonrpc_response(jsonRpcVer, request.id, doc.hover(request.params.position));

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
            if (SymbolUsageFastMap{string(symbolInfo.usage)})
                if (!SymbolUsageFastMap{string(symbolInfo.usage)}.contains(symbols[i].kind))
                    splice symbols, i, 1;
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

    #! "textDocument/signatureHelp" method handler
    private:internal *string meth_td_signatureHelp(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/references" method handler
    private:internal *string meth_td_references(hash request) {
        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::referenceParams(request);
        if (validation)
            return validation;

        if (!exists documents{request.params.textDocument.uri})
            return ErrorResponse::nonExistentDocument(request);

        # find references
        Document doc = documents{request.params.textDocument.uri};
        *list references = doc.findReferences(request.params.position, request.params.context.includeDeclaration);
        return make_jsonrpc_response(jsonRpcVer, request.id, references ?? list());
    }

    #! "textDocument/documentHighlight" method handler
    private:internal *string meth_td_documentHighlight(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/documentSymbol" method handler
    private:internal *string meth_td_documentSymbol(hash request) {
        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::textDocumentIdentifier(request);
        if (validation)
            return validation;

        if (!exists documents{request.params.textDocument.uri})
            return ErrorResponse::nonExistentDocument(request);

        # find document symbols
        Document doc = documents{request.params.textDocument.uri};
        *list symbols = doc.findSymbols();
        return make_jsonrpc_response(jsonRpcVer, request.id, symbols ?? list());
    }

    #! "textDocument/formatting" method handler
    private:internal *string meth_td_formatting(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/rangeFormatting" method handler
    private:internal *string meth_td_rangeFormatting(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/onTypeFormatting" method handler
    private:internal *string meth_td_onTypeFormatting(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/definition" method handler
    private:internal *string meth_td_definition(hash request) {
        # validate request
        if (!request.hasKey("params"))
            return ErrorResponse::invalidRequest(request, "required attribute 'params' is missing");

        *string validation = ParamValidator::textDocumentPositionParams(request);
        if (validation)
            return validation;

        if (!exists documents{request.params.textDocument.uri})
            return ErrorResponse::nonExistentDocument(request);

        # get the document
        Document doc = documents{request.params.textDocument.uri};

        # find requested symbol in the document
        *hash symbolInfo = doc.findSymbolInfo(request.params.position);
        if (!symbolInfo)
            return make_jsonrpc_response(jsonRpcVer, request.id, list());

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
            if (SymbolUsageFastMap{string(symbolInfo.usage)})
                if (!SymbolUsageFastMap{string(symbolInfo.usage)}.contains(symbols[i].kind))
                    splice symbols, i, 1;
        }

        # prepare results
        list result = map $1.location, symbols;
        return make_jsonrpc_response(jsonRpcVer, request.id, result);
    }

    #! "textDocument/codeAction" method handler
    private:internal *string meth_td_codeAction(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/codeLens" method handler
    private:internal *string meth_td_codeLens(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "codeLens/resolve" method handler
    private:internal *string meth_codeLens_resolve(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/documentLink" method handler
    private:internal *string meth_td_documentLink(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "documentLink/resolve" method handler
    private:internal *string meth_documentLink_resolve(hash request) {
        return ErrorResponse::methodNotFound(request);
    }

    #! "textDocument/rename" method handler
    private:internal *string meth_td_rename(hash request) {
        return ErrorResponse::methodNotFound(request);
    }
}
