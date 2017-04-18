/* -*- mode: c++; indent-tabs-mode: nil -*- */
/*
  AstParserHolder.h

  AstParser C++ class

  Qore AST Parser

  Copyright (C) 2017 Qore Technologies, s.r.o.

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

#ifndef _QLS_ASTPARSERHOLDER_H
#define _QLS_ASTPARSERHOLDER_H

#include <qore/Qore.h>

class AstParser;

class AstParserHolder : public AbstractPrivateData {
private:
    AstParser* parser;

public:
    AstParserHolder() {}
    ~AstParserHolder() {}

    int parseFile(const char* filename);
    int parseFile(std::string& filename);

    int parseString(const char* str);
    int parseString(std::string& str);
};

#endif // _QLS_ASTPARSERHOLDER_H