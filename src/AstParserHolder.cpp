/* -*- mode: c++; indent-tabs-mode: nil -*- */
/*
  AstParserHolder.cpp

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

#include "AstParserHolder.h"
#include "AstParser.h"

AstParserHolder::AstParserHolder() {
    parser = new AstParser;
}

AstParserHolder::~AstParserHolder() {
    delete parser;
}

int AstParserHolder::parseFile(const char* filename) {
    return parser->parseFile(filename);
}

int AstParserHolder::parseFile(std::string& filename) {
    return parser->parseFile(filename);
}

int AstParserHolder::parseString(const char* filename) {
    return parser->parseString(filename);
}

int AstParserHolder::parseString(std::string& filename) {
    return parser->parseString(filename);
}

ASTNode* AstParserHolder::findNode(int line, int col) {
    return parser->findNode(line, col);
}

ASTTree* AstParserHolder::getTreePtr() {
    return parser->getTreePtr();
}

ASTTree* AstParserHolder::releaseTree() {
    return parser->releaseTree();
}

size_t AstParserHolder::getErrorCount() const {
    return parser->getErrorCount();
}

ASTParseError* AstParserHolder::getError(unsigned int index) {
    return parser->getError(index);
}