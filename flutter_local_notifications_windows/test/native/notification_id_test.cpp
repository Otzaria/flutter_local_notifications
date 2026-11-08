#include "../../src/notification_ids.hpp"

#include <climits>
#include <iostream>
#include <string_view>

static bool accepts(std::string_view text, int expected) {
  int parsed = 77;
  return tryParseNotificationId(text, parsed) && parsed == expected;
}

static bool rejects(std::string_view text) {
  int parsed = 77;
  return !tryParseNotificationId(text, parsed);
}

int main() {
  if (!accepts("0", 0) || !accepts("-1", -1) ||
      !accepts("2147483647", INT_MAX) || !accepts("-2147483648", INT_MIN) ||
      !rejects("") || !rejects("abc") || !rejects("1abc") ||
      !rejects(" 42") || !rejects("42 ") || !rejects("+42") ||
      !rejects("2147483648") || !rejects("-2147483649")) {
    std::cerr << "notification ID parsing regression\n";
    return 1;
  }
  std::cout << "notification ID parsing: valid, malformed and integer-boundary cases passed\n";
}
