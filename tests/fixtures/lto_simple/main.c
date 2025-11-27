// Test file for LTO - main program
// This should inline functions from utils.c during LTO

// Function declarations (defined in utils.c)
int add(int a, int b);
int multiply(int a, int b);
int square(int x);

int compute(int x, int y) {
  int sum = add(x, y);
  int product = multiply(x, y);
  int sq = square(x);
  return sum + product + sq;
}

int main(int argc, char **argv) {
  return compute(argc, (long)argv[0]);
}
