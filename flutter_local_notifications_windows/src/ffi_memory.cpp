#include "ffi_api.h"

// Keep deallocation independent of WinRT so its allocator contract can be tested
// without registering an app or contacting the Windows notification service.
void freeDetailsArray(NativeNotificationDetails* ptr) { delete[] ptr; }

void freeLaunchDetails(NativeLaunchDetails details) {
  if (details.payload != nullptr) delete[] details.payload;
  if (details.data.entries != nullptr) {
    for (int index = 0; index < details.data.size; index++) {
      const auto pair = details.data.entries[index];
      // toNativeString allocates both strings with new char[].
      delete[] pair.key;
      delete[] pair.value;
    }
  }
  if (details.data.entries != nullptr) delete[] details.data.entries;
}
