import 'dart:async';
import 'dart:ffi';

import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:test/test.dart';

void requireCondition(bool condition, String description) {
  if (!condition) throw StateError(description);
}

void main() {
  test('native 650ms stalls do not freeze queries or disposal', () async {
    final DynamicLibrary fixture = DynamicLibrary.open(
      'flutter_local_notifications_windows.dll',
    );
    final void Function(int) setFailureMode = fixture
        .lookupFunction<Void Function(Int32), void Function(int)>(
          'setQueryFailureMode',
        );
    final int Function() createCount = fixture
        .lookupFunction<Int32 Function(), int Function()>('stubCreateCount');

    const WindowsInitializationSettings goodSettings =
        WindowsInitializationSettings(
          appName: 'responsiveness-probe',
          appUserModelId: 'com.test.notifications',
          guid: 'a8c22b55-049e-422f-b30f-863694de08c8',
        );

    final FlutterLocalNotificationsWindows bad =
        FlutterLocalNotificationsWindows();
    final int beforeInvalid = createCount();
    try {
      await bad.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'bad',
          appUserModelId: 'com.test.bad',
          guid: 'zzzzzzzz-049e-422f-b30f-863694de08c8',
        ),
      );
      throw StateError('Expected invalid GUID to fail');
    } on ArgumentError {
      requireCondition(
        createCount() == beforeInvalid,
        'Invalid GUID allocated a native worker',
      );
    }

    final FlutterLocalNotificationsWindows plugin =
        FlutterLocalNotificationsWindows();
    requireCondition(
      await plugin.initialize(settings: goodSettings),
      'Fixture plugin did not initialize',
    );

    final Stopwatch clock = Stopwatch()..start();
    int previousTick = clock.elapsedMilliseconds;
    int maxTickGap = 0;
    int ticks = 0;
    final Timer timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      final int now = clock.elapsedMilliseconds;
      final int gap = now - previousTick;
      if (gap > maxTickGap) maxTickGap = gap;
      previousTick = now;
      ticks++;
    });
    try {
      final Stopwatch queries = Stopwatch()..start();
      final Future<List<ActiveNotification>> active = plugin
          .getActiveNotifications();
      final Future<List<PendingNotificationRequest>> pending = plugin
          .pendingNotificationRequests();
      final Future<NotificationUpdateResult> update = plugin.updateBindings(
        id: 11,
        bindings: <String, String>{'value': '42'},
      );
      await Future.wait<void>(<Future<void>>[
        active.then<void>((_) {}),
        pending.then<void>((_) {}),
        update.then<void>((_) {}),
      ]);
      queries.stop();
      requireCondition(
        (await active).length == 2,
        'Active result was corrupted',
      );
      requireCondition(
        (await pending).single.id == 31,
        'Pending result was corrupted',
      );
      requireCondition(
        await update == NotificationUpdateResult.success,
        'Update result was corrupted',
      );
      requireCondition(
        queries.elapsedMilliseconds >= 600,
        'Fixture did not provide the intended blocking call',
      );
      Zone.current.print('queries total: ${queries.elapsedMilliseconds} ms');

      for (final int mode in <int>[1, 2]) {
        setFailureMode(mode);
        bool failedSafely = false;
        try {
          await plugin.getActiveNotifications();
        } on StateError {
          failedSafely = true;
        }
        requireCondition(failedSafely, 'Invalid native array was not rejected');
      }

      final Future<List<PendingNotificationRequest>> inFlight = plugin
          .pendingNotificationRequests();
      final Stopwatch quickDispose = Stopwatch()..start();
      plugin.dispose();
      quickDispose.stop();
      requireCondition(
        quickDispose.elapsedMilliseconds < 450,
        'dispose() blocked the main isolate',
      );
      await inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 850));

      final FlutterLocalNotificationsWindows second =
          FlutterLocalNotificationsWindows();
      await second.initialize(settings: goodSettings);
      final Stopwatch directDispose = Stopwatch()..start();
      second.dispose();
      directDispose.stop();
      requireCondition(
        directDispose.elapsedMilliseconds < 450,
        'idle dispose() blocked the main isolate',
      );
      await Future<void>.delayed(const Duration(milliseconds: 850));
      await Future<void>.delayed(const Duration(milliseconds: 75));
    } finally {
      timer.cancel();
    }
    requireCondition(ticks >= 30, 'UI-isolate timer did not progress');
    requireCondition(
      maxTickGap < 450,
      'UI-isolate timer stalled for ${maxTickGap}ms',
    );
    Zone.current.print(
      'UI timer: $ticks ticks; max gap: ${maxTickGap}ms (threshold 450ms)',
    );
  });
}
