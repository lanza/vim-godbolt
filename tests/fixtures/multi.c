int foo(int x) {
    return x + 1;
}

int bar(int y) {
    return y * 2;
}

int baz(int z) {
    return foo(z) + foo(z) + bar(z);
}
