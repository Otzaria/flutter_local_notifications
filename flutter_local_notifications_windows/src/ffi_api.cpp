#include <windows.h>  // <-- This must be the first Windows header
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Xml.Dom.h>

#include <memory>
#include <vector>

#include "notification_ids.hpp"

#include "ffi_api.h"
#include "plugin.hpp"
#include "utils.hpp"

using winrt::Windows::Data::Xml::Dom::XmlDocument;

bool hasPackageIdentity() {
  if (!IsWindows8OrGreater()) return false;
  uint32_t length = 0;
  int error = GetCurrentPackageFullName(&length, nullptr);
  return error != APPMODEL_ERROR_NO_PACKAGE;
}

NativePlugin* createPlugin() { return new NativePlugin(); }

void disposePlugin(NativePlugin* plugin) { delete plugin; }

bool init(
  NativePlugin* plugin, char* appName, char* aumId, char* guid, char* iconPath,
  NativeNotificationCallback callback, NativeInitCallback onReady
) {
  // The caller's strings live in a Dart arena that is freed when this returns, so
  // everything the worker needs is copied before queueing.
  const string name(appName);
  const string aumid(aumId);
  const string clsid(guid);
  string icon;
  if (iconPath != nullptr) icon = string(iconPath);
  return plugin->worker.post([plugin, name, aumid, clsid, icon, callback, onReady] {
    try {
      if (plugin->registerApp(aumid, name, clsid, icon, callback)) {
        plugin->hasIdentity = hasPackageIdentity();
        plugin->aumid = winrt::to_hstring(aumid);
        plugin->notifier = plugin->hasIdentity
          ? ToastNotificationManager::CreateToastNotifier()
          : ToastNotificationManager::CreateToastNotifier(plugin->aumid);
        plugin->history = ToastNotificationManager::History();
        plugin->isReady = true;
      }
    } catch (...) {
      // Reported as a failure below, so the caller never waits forever.
    }
    if (!plugin->isReady) plugin->resetRegistration();
    onReady(plugin->isReady);
  });
}

bool isValidXml(char* xml) {
  XmlDocument doc = XmlDocument();
  try {
    doc.LoadXml(winrt::to_hstring(xml));
    return true;
  } catch (winrt::hresult_error error) {
    return false;
  }
}

// Collects matches first: removing while iterating the scheduled view is unsafe.
static void removeScheduled(NativePlugin* plugin, const winrt::hstring& tag) {
  auto& notifier = plugin->notifier.value();
  std::vector<ScheduledToastNotification> matches;
  for (const auto notification : notifier.GetScheduledToastNotifications()) {
    if (notification.Tag() == tag) matches.push_back(notification);
  }
  for (const auto& notification : matches) notifier.RemoveFromSchedule(notification);
}

bool showNotification(NativePlugin* plugin, int id, char* xml, NativeStringMap bindings) {
  // Parsing is local, so a malformed document is still reported to the caller.
  if (!isValidXml(xml)) return false;
  const string xmlCopy(xml);
  const auto bindingsCopy = copyMap(bindings);
  plugin->worker.post([plugin, id, xmlCopy, bindingsCopy] {
    if (!plugin->isReady) return;
    XmlDocument doc;
    try {
      doc.LoadXml(winrt::to_hstring(xmlCopy));
    } catch (winrt::hresult_error error) {
      return;
    }
    ToastNotification notification(doc);
    notification.Tag(winrt::to_hstring(id));
    notification.Data(dataFromPairs(bindingsCopy));
    plugin->notifier.value().Show(notification);
  });
  return true;
}

bool scheduleNotification(NativePlugin* plugin, int id, char* xml, int64_t time) {
  if (!isValidXml(xml)) return false;
  const string xmlCopy(xml);
  plugin->worker.post([plugin, id, xmlCopy, time] {
    if (!plugin->isReady) return;
    XmlDocument doc;
    try {
      doc.LoadXml(winrt::to_hstring(xmlCopy));
    } catch (winrt::hresult_error error) {
      return;
    }
    const auto tag = winrt::to_hstring(id);
    removeScheduled(plugin, tag);
    const auto deliveryTime = winrt::clock::from_time_t(time);
    // The job may run late behind a stalled call, and AddToSchedule throws for a past time.
    if (deliveryTime <= winrt::clock::now()) {
      ToastNotification notification(doc);
      notification.Tag(tag);
      plugin->notifier.value().Show(notification);
      return;
    }
    ScheduledToastNotification notification(doc, deliveryTime);
    notification.Tag(tag);
    plugin->notifier.value().AddToSchedule(notification);
  });
  return true;
}

NativeUpdateResult updateNotification(NativePlugin* plugin, int id, NativeStringMap bindings) {
  NativeUpdateResult result = NativeUpdateResult::failed;
  plugin->worker.invoke([plugin, id, bindings, &result] {
    if (!plugin->isReady) return;
    const auto tag = winrt::to_hstring(id);
    const auto data = dataFromMap(bindings);
    result = (NativeUpdateResult) plugin->notifier.value().Update(data, tag);
  });
  return result;
}

void cancelAll(NativePlugin* plugin) {
  plugin->worker.post([plugin] {
    if (!plugin->isReady) return;
    if (plugin->hasIdentity) {
      plugin->history.value().Clear();
    } else {
      plugin->history.value().Clear(plugin->aumid);
    }
    for (const auto notification : plugin->notifier.value().GetScheduledToastNotifications()) {
      plugin->notifier.value().RemoveFromSchedule(notification);
    }
  });
}

void cancelNotification(NativePlugin* plugin, int id) {
  plugin->worker.post([plugin, id] {
    if (!plugin->isReady) return;
    const auto tag = winrt::to_hstring(id);
    if (plugin->hasIdentity) plugin->history.value().Remove(tag);
    removeScheduled(plugin, tag);
  });
}

// Toast history can include tags from other applications. Invalid and
// out-of-range tags are skipped rather than throwing after allocating a
// partially filled native array or reporting a non-null size with null data.
template <typename Notifications>
static NativeNotificationDetails* copyNotificationIds(
  const Notifications& notifications, int& count
) {
  std::vector<int> ids;
  for (const auto& notification : notifications) {
    int id = 0;
    if (tryParseNotificationId(winrt::to_string(notification.Tag()), id)) ids.push_back(id);
  }
  if (ids.empty()) return nullptr;
  auto result = std::make_unique<NativeNotificationDetails[]>(ids.size());
  for (size_t index = 0; index < ids.size(); ++index) result[index].id = ids[index];
  count = static_cast<int>(ids.size());
  return result.release();
}

NativeNotificationDetails* getActiveNotifications(NativePlugin* plugin, int* size) {
  NativeNotificationDetails* out = nullptr;
  int count = 0;
  plugin->worker.invoke([plugin, &out, &count] {
    if (!plugin->isReady || !plugin->hasIdentity) return;
    out = copyNotificationIds(plugin->history.value().GetHistory(), count);
  });
  *size = count;
  return out;
}

NativeNotificationDetails* getPendingNotifications(NativePlugin* plugin, int* size) {
  NativeNotificationDetails* out = nullptr;
  int count = 0;
  plugin->worker.invoke([plugin, &out, &count] {
    if (!plugin->isReady) return;
    out = copyNotificationIds(plugin->notifier.value().GetScheduledToastNotifications(), count);
  });
  *size = count;
  return out;
}
