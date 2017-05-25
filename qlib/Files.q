# -*- mode: qore; indent-tabs-mode: nil -*-

/*  Files.q Copyright 2017 Qore Technologies, s.r.o.

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

#! Find files in given path with given extension.
list sub findFilesWithExtension(string path, string extension) {
    list files = ();
    string out = backquote(sprintf("find %s -name \"*.%s\"", path, extension));
    DataLineIterator it(out);
    while (it.next()) {
        string file = it.getValue();
        if (file)
            files += file;
    }
    return files;
}

#! Find Qore files in given workspace path.
/**
    @return list of file paths
*/
list sub findQoreFilesInWorkspace(string workspacePath) {
    list qoreFiles = ();
    qoreFiles += findFilesWithExtension(workspacePath, "q");
    qoreFiles += findFilesWithExtension(workspacePath, "qm");
    qoreFiles += findFilesWithExtension(workspacePath, "qtest");
    qoreFiles += findFilesWithExtension(workspacePath, "ql");
    qoreFiles += findFilesWithExtension(workspacePath, "qc");
    qoreFiles += findFilesWithExtension(workspacePath, "qsd");
    qoreFiles += findFilesWithExtension(workspacePath, "qfd");
    qoreFiles += findFilesWithExtension(workspacePath, "qwf");
    qoreFiles += findFilesWithExtension(workspacePath, "qjob");
    qoreFiles += findFilesWithExtension(workspacePath, "qclass");
    qoreFiles += findFilesWithExtension(workspacePath, "qconst");
    qoreFiles += findFilesWithExtension(workspacePath, "qsm");
    return qoreFiles;
}

#! Find standard Qore module files.
/**
    @return list of file paths
*/
list sub findStdModuleFiles() {
    # find module path
    Program p(PO_NO_CHILD_PO_RESTRICTIONS | PO_NEW_STYLE);
    p.disableParseOptions(PO_NO_TOP_LEVEL_STATEMENTS);
    p.parse("%requires Util\nint x = 0;", "label", 0);
    hash mh = p.callFunction("get_module_hash");
    *string filename = mh.Util.filename;
    if (!filename)
        return list();
    string modulePath = dirname(filename);

    # find modules
    list moduleFiles = ();
    moduleFiles += findFilesWithExtension(modulePath, "qm");
    return moduleFiles;
}