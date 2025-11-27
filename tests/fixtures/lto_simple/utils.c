// Test file for LTO - utility functions
// This file should get inlined into main.c during LTO

int add(int a, int b) {
  return a + b;
}

int multiply(int a, int b) {
  return a * b;
}

int square(int x) {
  return multiply(x, x);
}
