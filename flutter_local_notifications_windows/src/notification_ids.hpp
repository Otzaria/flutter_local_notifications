#pragma once

#include <charconv>
#include <string_view>
#include <system_error>

// Internal, C++17-only parser: does not change the public native FFI ABI.
inline bool tryParseNotificationId(std::string_view tag, int& id) noexcept {
  if (tag.empty()) return false;
  const char* const begin = tag.data();
  const char* const end = begin + tag.size();
  const auto parsed = std::from_chars(begin, end, id);
  return parsed.ec == std::errc() && parsed.ptr == end;
}
