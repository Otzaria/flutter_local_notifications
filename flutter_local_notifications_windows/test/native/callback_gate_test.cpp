#include "../../src/callback_gate.hpp"

#include <atomic>
#include <cstring>
#include <iostream>
#include <memory>
#include <thread>

static std::atomic<int> delivered {0};

static void onLaunch(NativeLaunchDetails details) {
  ++delivered;
  freeLaunchDetails(details);
}

static NativeLaunchDetails makeDetails() {
  auto* payload = new char[8];
  std::memcpy(payload, "payload", 8);
  auto* entries = new StringMapEntry[1];
  auto* key = new char[4];
  auto* value = new char[4];
  std::memcpy(key, "key", 4);
  std::memcpy(value, "val", 4);
  entries[0] = {key, value};
  return {true, notification, payload, {entries, 1}};
}

int main() {
  auto gate = std::make_shared<NotificationCallbackGate>(&onLaunch);
  gate->deliver(makeDetails());
  std::thread worker([gate] {
    for (int i = 0; i < 4000; ++i) gate->deliver(makeDetails());
  });
  gate->close();
  const int afterClose = delivered.load();
  for (int i = 0; i < 4000; ++i) gate->deliver(makeDetails());
  worker.join();
  gate->close();
  if (delivered.load() != afterClose) {
    std::cerr << "callback fired after shutdown\n";
    return 1;
  }
  std::cout << "callback gate: no late calls; native buffers released\n";
}
