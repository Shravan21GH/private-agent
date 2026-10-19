import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/local_commands.dart';
import 'package:private_agent/services/memory_store.dart';
import 'package:private_agent/services/quick_commands.dart';
import 'package:private_agent/services/task_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Monday 19 October 2026, 10:00.
  final now = DateTime(2026, 10, 19, 10, 0);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DateWords', () {
    test('tomorrow at 5pm', () {
      final r = DateWords.parse('finish revision tomorrow at 5pm', now);
      expect(r.when, DateTime(2026, 10, 20, 17, 0));
      expect(r.hasTime, isTrue);
      expect(r.text, 'finish revision');
    });

    test('in 30 minutes', () {
      final r = DateWords.parse('call mom in 30 minutes', now);
      expect(r.when, now.add(const Duration(minutes: 30)));
      expect(r.text, 'call mom');
    });

    test('weekday', () {
      final r = DateWords.parse('submit report on friday', now);
      expect(r.when, DateTime(2026, 10, 23));
      expect(r.hasTime, isFalse);
      expect(r.text, 'submit report');
    });

    test('no date', () {
      final r = DateWords.parse('read a book', now);
      expect(r.when, isNull);
      expect(r.text, 'read a book');
    });
  });

  group('QuickCommand', () {
    test('open app', () {
      final c = QuickCommand.parse('open WhatsApp');
      expect(c?.type, QuickCommandType.openApp);
      expect(c?.target, 'WhatsApp');
    });

    test('play store search', () {
      final c = QuickCommand.parse('open playstore and type WhatsApp');
      expect(c?.type, QuickCommandType.playStoreSearch);
      expect(c?.target, 'WhatsApp');
    });

    test('longer instructions go to the AI', () {
      expect(QuickCommand.parse('open settings and turn on wifi'), isNull);
    });
  });

  group('TaskStore', () {
    test('add, complete, duplicate, overdue', () async {
      final store = TaskStore();
      final first = await store.add('Finish science', due: DateTime(2026, 10, 18));
      expect(first.created, isTrue);
      expect(first.task.isOverdue(now), isTrue);

      final again = await store.add('finish science', due: DateTime(2026, 10, 18));
      expect(again.created, isFalse);

      expect(await store.setDone(first.task.id, true), isTrue);
      expect((await store.pending()), isEmpty);
      expect((await store.completed()).length, 1);
    });

    test('survives a restart (new store instance)', () async {
      await TaskStore().add('Keep me');
      final reloaded = await TaskStore().pending();
      expect(reloaded.single.title, 'Keep me');
    });

    test('damaged data is recovered', () async {
      SharedPreferences.setMockInitialValues({'zax_tasks_v1': '{not json'});
      final store = TaskStore();
      expect(await store.pending(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('zax_tasks_v1_corrupt_backup'), '{not json');
    });
  });

  group('MemoryStore', () {
    test('saves, detects duplicates, refuses secrets', () async {
      final store = MemoryStore();
      expect((await store.remember('My favourite colour is blue')).status, MemoryStatus.saved);
      expect((await store.remember('my favourite colour is blue')).status, MemoryStatus.duplicate);
      expect((await store.remember('my password is hunter2')).status, MemoryStatus.rejectedSecret);
      expect((await store.remember('I take medication daily')).status, MemoryStatus.needsConfirmation);
      expect((await store.items()).length, 1);
    });

    test('a corrected fact updates the old one', () async {
      final store = MemoryStore();
      await store.remember('my favourite colour is blue');
      final r = await store.remember('my favourite colour is red');
      expect(r.status, MemoryStatus.updated);
      expect((await store.items()).single.text, 'my favourite colour is red');
    });

    test('context only includes relevant memories', () async {
      final store = MemoryStore();
      await store.remember('my dog is called Bruno');
      expect(await store.contextFor('what should I feed my dog?'), contains('Bruno'));
      expect(await store.contextFor('what is the capital of France?'), isEmpty);
    });
  });

  group('LocalCommands', () {
    LocalCommands make({List<String>? log}) => LocalCommands(
      tasks: TaskStore(),
      memory: MemoryStore(),
      clock: () => now,
      scheduleReminder: (when, label) async {
        log?.add('$when|$label');
        return null;
      },
    );

    test('create a goal, then "I finished it. Tick it."', () async {
      final zax = make();
      final created = await zax.handle("Zax, create a goal for today's tasks: finish my science revision");
      expect(created, startsWith('Saved task'));
      expect(created, contains('finish my science revision'));

      final done = await zax.handle('I finished it. Tick it.');
      expect(done, contains('Marked as done'));
    });

    test('ambiguous completion asks which one', () async {
      final zax = make();
      await zax.handle('create a task: study maths chapter 1');
      await zax.handle('create a task: study maths chapter 2');
      final ask = await zax.handle('tick off study maths');
      expect(ask, contains('Which one'));
      final done = await zax.handle('2');
      expect(done, contains('Marked as done'));
    });

    test('reminder is only reported as sent when scheduling returns null', () async {
      final log = <String>[];
      final zax = make(log: log);
      final reply = await zax.handle('remind me to call mom at 5pm');
      expect(reply, contains('reminder request'));
      expect(log, hasLength(1));
    });

    test('failed reminder is reported honestly', () async {
      final zax = LocalCommands(
        tasks: TaskStore(),
        memory: MemoryStore(),
        clock: () => now,
        scheduleReminder: (when, label) async => 'the Clock app could not be reached.',
      );
      final reply = await zax.handle('remind me to call mom at 5pm');
      expect(reply, contains('could not set the reminder'));
    });

    test('memory commands', () async {
      final zax = make();
      expect(await zax.handle('remember my favourite subject is physics'), contains('Saved to memory'));
      expect(await zax.handle('what do you remember about me?'), contains('physics'));
      expect(await zax.handle('remember my pin is 4321'), contains('never store'));
    });

    test('normal chat is left for the AI', () async {
      final zax = make();
      expect(await zax.handle('what is the capital of France?'), isNull);
      expect(await zax.handle('remember when we talked about space?'), isNull);
    });
  });
}
