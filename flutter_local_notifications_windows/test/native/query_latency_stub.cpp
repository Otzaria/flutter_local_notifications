// Test-only ABI fixture: deliberately slow C calls, without WinRT.
#include "../../src/ffi_api.h"
#include <atomic>
#include <chrono>
#include <thread>

struct NativePlugin {
  NativeNotificationCallback callback = nullptr;
};
static std::atomic<int> failureMode {0};
static std::atomic<int> createCount {0};
static void delay() { std::this_thread::sleep_for(std::chrono::milliseconds(650)); }

extern "C" FFI_PLUGIN_EXPORT void setQueryFailureMode(int mode) { failureMode = mode; }
extern "C" FFI_PLUGIN_EXPORT int stubCreateCount() { return createCount.load(); }

NativePlugin* createPlugin() {
  ++createCount;
  return new NativePlugin();
}
bool init(
  NativePlugin* plugin, char*, char*, char*, char*, NativeNotificationCallback callback
) {
  plugin->callback = callback;
  return true;
}
void disposePlugin(NativePlugin* plugin) {
  delay();
  delete plugin;
}
NativeNotificationDetails* getActiveNotifications(NativePlugin*, int* size) {
  delay();
  const int mode = failureMode.exchange(0);
  if (mode == 1) { *size = 2; return nullptr; }
  if (mode == 2) { *size = -1; return nullptr; }
  *size = 2;
  return new NativeNotificationDetails[2] {{11}, {12}};
}
NativeNotificationDetails* getPendingNotifications(NativePlugin*, int* size) {
  delay();
  *size = 1;
  return new NativeNotificationDetails[1] {{31}};
}
NativeUpdateResult updateNotification(NativePlugin*, int, NativeStringMap) {
  delay();
  return NativeUpdateResult::success;
}
void freeDetailsArray(NativeNotificationDetails* ptr) { delete[] ptr; }
void freeLaunchDetails(NativeLaunchDetails details) {
  delete[] details.payload;
  if (details.data.entries != nullptr) {
    for (int i = 0; i < details.data.size; ++i) {
      delete[] details.data.entries[i].key;
      delete[] details.data.entries[i].value;
    }
  }
  delete[] details.data.entries;
}
