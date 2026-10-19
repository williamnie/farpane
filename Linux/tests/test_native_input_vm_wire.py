"""Protocol vectors and bounds for the private input VM test peer."""
import unittest
import native_input_vm_wire as wire


class WireEncoding(unittest.TestCase):
    def test_seq_default_flags_match_mac_input_string(self):
        data=wire.seq_message('中文测试')
        # Message.key_event=15, KeyEvent.seq=6; all other fields absent.
        self.assertEqual(data.hex(),'7a0e320ce4b8ade69687e6b58be8af95')
        self.assertEqual(wire.decode(wire.decode(data)[15]),{6:'中文测试'.encode()})
        self.assertEqual(wire.frame(data),b'\x40'+data)

    def test_frame_boundaries_match_upstream_bytes_codec(self):
        for size,head in [(0,'00'),(63,'fc'),(64,'0101'),(16383,'fdff'),
                          (16384,'020001'),(4194303,'feffff'),(4194304,'03000001')]:
            with self.subTest(size=size):
                packet=wire.frame(b'x'*size)
                self.assertEqual(packet[:len(bytes.fromhex(head))].hex(),head)
        with self.assertRaises(AssertionError):wire.frame(b'x'*(wire.MAX_PACKET+1))

    def test_reject_truncated_or_overflowed_fields(self):
        for data in (b'\x32\x04abc',b'\x32\x80',b'\x08'+b'\xff'*10,
                     b'\x08'+b'\xff'*9+b'\x02',b'\x00',b'\x0b'):
            with self.subTest(data=data),self.assertRaises((AssertionError,ValueError)):
                wire.decode(data)


if __name__=='__main__':unittest.main()
