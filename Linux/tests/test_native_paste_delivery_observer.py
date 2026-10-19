import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('paste_observer',
    ROOT / 'Scripts/linux/observe-paste-delivery.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


def line(message, level='INFO'):
    return f'[2026-10-18 21:52:25.510093 -07:00] {level} [src/server/input_service.rs:2012] {message}'


class LogClassification(unittest.TestCase):
    def test_stage_records_carry_only_fixed_fields(self):
        record = observer.classify(line(
            'Native committed text #44: chars=1 ascii=false released_modifiers=0b000 (x2)'))
        self.assertEqual(record['stage'], 'commit')
        self.assertEqual((record['commit'], record['chars'], record['repeat']), (44, 1, 2))
        self.assertAlmostEqual(record['log_wall'], 1792385545.510093, places=5)

    def test_error_details_and_text_cannot_escape(self):
        secret = '中文测试 secret device 1000000000'
        for message in (f'set_clipboard_content: failed to set clipboard with owner marker: {secret}',
                        f'Native committed text #7 dropped: chars=4 ascii=false; {secret}',
                        f'Native committed text: clipboard restore failed: {secret}',
                        f'Native committed text: IBus unavailable; using paste: {secret}'):
            record = observer.classify(line(message))
            self.assertIsNotNone(record)
            self.assertNotIn('secret', repr(record))
            self.assertNotIn('中文', repr(record))

    def test_ibus_stages_are_recognised(self):
        self.assertEqual(observer.classify(line('Native committed text: IBus commit sent', 'DEBUG'))['stage'],
                         'ibus_committed')
        self.assertEqual(observer.classify(line(
            'Native committed text: no IBus client focused; using paste', 'DEBUG'))['stage'], 'ibus_no_client')

    def test_unlisted_and_suffixed_messages_are_omitted(self):
        for message in ('handle_keyboard received: Layout(secret)',
                        'Native committed text: paste key sequence queued and secret',
                        'peer username and address'):
            self.assertIsNone(observer.classify(line(message)))
        self.assertIsNone(observer.classify('raw continuation line with secret'))

    def test_log_tail_starts_at_end_and_follows_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'core.log'
            path.write_text(line('Native committed text: clipboard ready; preparing paste', 'DEBUG') + '\n')
            tail = observer.LogTail(path)
            self.assertEqual(tail.poll(), [])
            with open(path, 'a') as handle:
                handle.write(line('Native committed text: paste key sequence queued', 'DEBUG'))
            self.assertEqual(tail.poll(), [], 'a partial line waits for its newline')
            with open(path, 'a') as handle:
                handle.write('\n')
            self.assertEqual([r['stage'] for r in tail.poll()], ['paste_queued'])
            path.unlink()
            path.write_text(line('Native paste clipboard written in 0 ms') + '\n')
            self.assertEqual([r['stage'] for r in tail.poll()], ['clipboard_written'])
            tail.handle.close()


class XProtocol(unittest.TestCase):
    def test_xauthority_picks_the_display_cookie(self):
        def entry(number, cookie):
            fields = [b'host', number, b'MIT-MAGIC-COOKIE-1', cookie]
            return struct.pack('>H', 256) + b''.join(struct.pack('>H', len(f)) + f for f in fields)
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(entry(b'1', b'one') + entry(b'0', b'zero'))
            handle.flush()
            self.assertEqual(observer.xauth_cookie(handle.name, 0), b'zero')
            self.assertEqual(observer.xauth_cookie(handle.name, 5), b'one')

    def test_record_reply_exposes_only_selection_and_key_codes(self):
        def reply(category, data):
            head = struct.pack('<BBHIBBxxIII', 1, category, 0, len(data) // 4, 0, 0, 0x400000, 0, 0)
            return head + b'\0' * (32 - len(head)) + data
        convert = struct.pack('<BxHIIIII', 24, 6, 0x1, 2, 3, 4, 0)
        self.assertEqual(list(observer.parse_record(reply(1, convert))),
                         [('convert', 0x400000, {'selection': 2, 'target': 3})])
        keys = struct.pack('<BB30x', 2, 118) + struct.pack('<BB30x', 3, 38)
        self.assertEqual([f for _, _, f in observer.parse_record(reply(0, keys))],
                         [{'down': True, 'keycode': 118}, {'down': False, 'keycode': 38}])


class Summary(unittest.TestCase):
    def test_x_records_attach_to_the_paste_that_preceded_them(self):
        records = [
            {'source': 'core_log', 'stage': 'commit', 'log_wall': 9.95, 'commit': 3, 'chars': 2, 'ascii': False},
            {'source': 'owner', 'selection': 'CLIPBOARD', 'owner': 'farpane-core', 'wall': 9.951},
            {'source': 'core_log', 'stage': 'paste_preparing', 'log_wall': 10.0},
            {'source': 'key', 'key': 'Insert', 'down': True, 'wall': 10.002},
            {'source': 'convert', 'selection': 'CLIPBOARD', 'requestor': 'warp',
             'target': 'UTF8_STRING', 'wall': 10.01},
        ]
        [paste] = observer.summarize(records)
        self.assertEqual((paste['commit'], paste['via']), (3, 'paste'))
        self.assertEqual(paste['owners'], ['CLIPBOARD:farpane-core@-49.0ms'])
        self.assertEqual(paste['keys'], ['Insert↓@2.0ms'])
        self.assertEqual(paste['reads'], ['CLIPBOARD:warp:UTF8_STRING@10.0ms'])


if __name__ == '__main__':
    unittest.main()
