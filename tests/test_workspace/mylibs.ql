
sub mylog(string msg) {
    printf("%s\n", vsprintf(msg, argv));
}

int sub foo(int i) {
    mylog("foo");
    return i;
}

