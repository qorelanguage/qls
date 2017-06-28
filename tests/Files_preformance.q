#!/usr/bin/env qore
# -*- mode: qore; indent-tabs-mode: nil -*-

/* a performance test script - not a real test to be automated
 */

%new-style

%include ../qlib/Files.q


*string path = shift ARGV;
if (!exists path) {
    printf("please use path to dir as an argument\n");
    exit(1);
}

date start = now_ms();
printf("start: %n\n", start);

list files = Files::find_qore_files(path);

date end = now_ms();
printf("  end: %n\n", end);
printf("duration: %n\n", end-start);
printf("list size: %n\n", files.size());
