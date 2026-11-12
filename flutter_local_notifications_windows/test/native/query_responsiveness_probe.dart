import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_local_notifications_windows/src/ffi/bindings.dart'
    as native;

import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart';
import 'package:timezone/timezone.dart';

void requireCondition(bool condition, String description) {
  if (!condition) throw StateError(description);
}

void main() {
  setUpAll(initializeTimeZones);
  const WindowsInitializationSettings retrySettings =
      WindowsInitializationSettings(
        appName: 'initialization-probe',
        appUserModelId: 'com.test.retry',
        guid: 'a8c22b55-049e-422f-b30f-863694de08c8',
      );
  final DynamicLibrary fixture = DynamicLibrary.open(
    'flutter_local_notifications_windows.dll',
  );
  final void Function(int) setInitFailures = fixture
      .lookupFunction<Void Function(Int), void Function(int)>(
        'setInitFailures',
      );
  final int Function() createCount = fixture
      .lookupFunction<Int Function(), int Function()>('stubCreateCount');
  final int Function() destroyCount = fixture
      .lookupFunction<Int Function(), int Function()>('stubDestroyCount');
  final int Function() initCount = fixture
      .lookupFunction<Int Function(), int Function()>('stubInitCount');
  final int Function() scheduledTime = fixture
      .lookupFunction<Int64 Function(), int Function()>('stubScheduledTime');
  final int Function() callbackAddress = fixture
      .lookupFunction<UintPtr Function(), int Function()>(
        'stubCallbackAddress',
      );
  setUp(() => setInitFailures(0));

  Future<void> disposePlugin(FlutterLocalNotificationsWindows plugin) async {
    plugin.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 850));
  }

  test('the generated schedule binding requests a 64-bit timestamp', () {
    Pointer<T> lookup<T extends NativeType>(String name) {
      expect(
        T,
        NativeFunction<
          Bool Function(Pointer<native.NativePlugin>, Int, Pointer<Utf8>, Int64)
        >,
      );
      return fixture.lookup<T>(name);
    }

    final native.NotificationsPluginBindings bindings =
        native.NotificationsPluginBindings.fromLookup(lookup);
    expect(
      bindings.scheduleNotification(nullptr, 1, nullptr, 7258118400),
      isTrue,
    );
    expect(scheduledTime(), 7258118400);
  });

  test(
    'scheduled seconds cross the signed 32-bit boundary unchanged',
    () async {
      final FlutterLocalNotificationsWindows plugin =
          FlutterLocalNotificationsWindows();
      addTearDown(() => disposePlugin(plugin));
      expect(await plugin.initialize(settings: retrySettings), isTrue);
      for (final TZDateTime date in <TZDateTime>[
        TZDateTime(UTC, 2037, 1, 1),
        TZDateTime.fromMillisecondsSinceEpoch(UTC, 2147483647000),
        TZDateTime.fromMillisecondsSinceEpoch(UTC, 2147483648000),
        TZDateTime(UTC, 2040, 1, 1),
        TZDateTime(UTC, 2100, 1, 1),
        TZDateTime(UTC, 2200, 1, 1),
      ]) {
        final int expected = date.millisecondsSinceEpoch ~/ 1000;
        await plugin.zonedSchedule(id: 1, scheduledDate: date, title: 'future');
        expect(scheduledTime(), expected, reason: '$date normal schedule');
        await plugin.zonedScheduleRawXml(
          id: 1,
          xml: '<toast/>',
          scheduledDate: date,
        );
        expect(scheduledTime(), expected, reason: '$date raw XML schedule');
      }
    },
  );

  test('a failed registration can retry on one native plugin', () async {
    final FlutterLocalNotificationsWindows plugin =
        FlutterLocalNotificationsWindows();
    addTearDown(() => disposePlugin(plugin));
    final int created = createCount();
    final int destroyed = destroyCount();
    final int initialized = initCount();
    setInitFailures(1);
    expect(await plugin.initialize(settings: retrySettings), isFalse);
    final int firstCallback = callbackAddress();
    expect(plugin.pendingNotificationRequests(), throwsStateError);
    final Future<bool> first = plugin.initialize(settings: retrySettings);
    final Future<bool> shared = plugin.initialize(settings: retrySettings);
    expect(await Future.wait(<Future<bool>>[first, shared]), <bool>[
      true,
      true,
    ]);
    expect(createCount(), created + 1);
    expect(initCount(), initialized + 2);
    expect(destroyCount(), destroyed);
    expect(callbackAddress(), firstCallback);
  });

  test('repeated failed registrations remain explicitly disposable', () async {
    final FlutterLocalNotificationsWindows plugin =
        FlutterLocalNotificationsWindows();
    addTearDown(() => disposePlugin(plugin));
    final int created = createCount();
    final int destroyed = destroyCount();
    setInitFailures(2);
    expect(await plugin.initialize(settings: retrySettings), isFalse);
    expect(await plugin.initialize(settings: retrySettings), isFalse);
    expect(createCount(), created + 1);
    expect(destroyCount(), destroyed);
    await disposePlugin(plugin);
    expect(destroyCount(), destroyed + 1);
    expect(plugin.initialize(settings: retrySettings), throwsStateError);
    plugin.dispose();
  });
  test('dispose during failed initialization releases one plugin', () async {
    final FlutterLocalNotificationsWindows plugin =
        FlutterLocalNotificationsWindows();
    final int destroyed = destroyCount();
    setInitFailures(1);
    final Future<bool> initializing = plugin.initialize(
      settings: retrySettings,
    );
    plugin.dispose();
    expect(await initializing, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(destroyCount(), destroyed + 1);
    expect(plugin.initialize(settings: retrySettings), throwsStateError);
    plugin.dispose();
  });
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
