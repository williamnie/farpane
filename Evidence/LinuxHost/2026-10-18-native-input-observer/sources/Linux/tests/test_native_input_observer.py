import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('input_observer',
    ROOT / 'Scripts/linux/observe-native-input.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


def record(source, message):
    return b'[2026-10-18 10:20:30.123456 +00:00] WARN [src/' + source + b':12] ' + message


class PrivacyAndFraming(unittest.TestCase):
    def test_error_details_cannot_escape(self):
        text = 'secret clipboard 中文测试 and device ID'.encode()
        line = record(b'server/input_service.rs',
            b'set_clipboard_content: failed to set clipboard with owner marker: ' + text)
        self.assertEqual(observer.classify(line), 'input_clipboard_set_failed')
        self.assertNotIn('secret', repr(observer.Lines().feed(line + b'\n')))

    def test_unknown_and_normal_key_messages_are_omitted(self):
        for line in (record(b'server/connection.rs', b'peer username and IP'),
                     record(b'server/uinput.rs', b'handle_keyboard received: Layout(secret)'),
                     record(b'server/input_service.rs', b'Fixed Control'),
                     b'raw multiline secret'):
            self.assertIsNone(observer.classify(line))

    def test_message_substrings_and_wrong_source_do_not_match(self):
        prefix = b'Native input key-state query failed: secret'
        self.assertIsNone(observer.classify(record(b'server/connection.rs', prefix)))
        self.assertIsNone(observer.classify(record(b'server/uinput.rs', b'unrelated ' + prefix)))

    def test_partial_lines_preserve_count_without_content(self):
        reader = observer.Lines()
        line = record(b'server/uinput.rs', b'UInputKeyboard::key_sequence called (len=12)')
        self.assertEqual(reader.feed(line[:65]), {})
        self.assertEqual(reader.feed(line[65:] + b'\n'), {'uinput_sequence_call': 1})

    def test_overlong_line_is_dropped_and_next_record_survives(self):
        reader = observer.Lines()
        self.assertEqual(reader.feed(b'x' * 8193), {})
        line = record(b'server/uinput.rs', b'Native input key-state query failed: private')
        self.assertEqual(reader.feed(line + b'\n' + line + b'\n'), {'input_state_query_failed': 1})
        self.assertEqual(reader.oversize, 1)

    def test_sequence_lengths_not_exported(self):
        reader = observer.Lines()
        first = record(b'server/uinput.rs', b'UInputKeyboard::key_sequence called (len=123456)')
        self.assertEqual(reader.feed(first + b'\n'), {'uinput_sequence_call': 1})

    def test_tail_excludes_history_and_rejects_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            line = record(b'server/uinput.rs', b'Native input key-state query failed: private') + b'\n'
            path.write_bytes(line)
            tail = observer.LogTail(os.getpid(), os.getuid(), path)
            try:
                self.assertEqual(tail.read(), {})
                with path.open('ab') as stream:
                    stream.write(line)
                self.assertEqual(tail.read(), {'input_state_query_failed': 1})
                path.rename(path.with_suffix('.old'))
                path.write_bytes(line)
                with self.assertRaises(ValueError):
                    tail.read()
            finally:
                tail.close()

    def test_tail_rejects_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            path.write_bytes(b'old private log\n')
            tail = observer.LogTail(os.getpid(), os.getuid(), path)
            try:
                path.write_bytes(b'')
                with self.assertRaises(ValueError):
                    tail.read()
            finally:
                tail.close()


if __name__ == '__main__':
    unittest.main()
