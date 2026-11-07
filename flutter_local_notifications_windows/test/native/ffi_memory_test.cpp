#include "../../src/ffi_api.h"

#include <cstring>
#include <iostream>

// Match the allocation contract of toNativeString; no Dart arena owns these.
static char* copyString(const char* value) {
  const auto size = std::strlen(value) + 1;
  auto* result = new char[size];
  std::memcpy(result, value, size);
  return result;
}

int main() {
  // Safe empty callback, including the absent optional payload/map.
  freeLaunchDetails({false, notification, nullptr, {nullptr, 0}});

  // Runtime size also covers the new T[count] path when an API returns zero.
  volatile int emptySize = 0;
  // An allocated empty array still belongs to the callback consumer.
  freeLaunchDetails({true, notification, copyString(""), {new StringMapEntry[emptySize], 0}});

  // Payload-only callbacks have no input map.
  freeLaunchDetails({true, action, copyString("payload"), {nullptr, 0}});

  // Exercise every string and the map array repeatedly. AddressSanitizer must
  // check alloc_dealloc_mismatch=1 (Windows disables that check by default).
  for (int iteration = 0; iteration < 10000; ++iteration) {
    const auto entries = new StringMapEntry[3]{
      {copyString("input"), copyString("value")},
      {copyString(""), copyString("")},
      {copyString("utf8"), copyString("\xD7\x90\xD7\x91")},
    };
    freeLaunchDetails({true, action, copyString("payload"), {entries, 3}});
  }

  // The public query-array deallocator retains its existing ABI and behavior.
  freeDetailsArray(nullptr);
  freeDetailsArray(new NativeNotificationDetails[emptySize]);
  freeDetailsArray(new NativeNotificationDetails[2]{{1}, {2}});

  std::cout << "ffi memory: empty, allocated-empty, payload-only, 10000 input maps, query arrays passed\n";
}
