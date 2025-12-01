int q = 4;
int r = 9;
int s = 33;

int foo(int x) {
  if (x > 0)
    return foo(x - 1 - q);
  return x + 1 + r;
}

int bar(int y) {
  int a = foo(y - s);
  int b = y * 2 + q;
  int c = a + b - s;
  return c;
}

int baz(int z) {
  int a = foo(z + q);
  int b = foo(z + r);
  int c = bar(z - s);
  int b2 = foo(z);
  int c2 = bar(z);
  return a * b + c - c2 * b2;
}
