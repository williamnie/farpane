//! Native message ownership and release of completely flushed large TCP buffers.
use base::message_proto::Message;
use bytes::{Bytes, BytesMut};
use hbb_common::{protobuf, protobuf::Message as _, stream::Stream};

pub fn decode(bytes: Bytes) -> protobuf::Result<Message> {
    // The generated protocol uses Bytes fields. A slice-based parser copies
    // each field, whereas this entry point lets it retain the received owner.
    Message::parse_from_tokio_bytes(&bytes)
}

pub fn release_large_write_buffer(peer: &mut Stream, message: &Message) {
    if message.compute_size() <= 1024 * 1024 {
        return;
    }
    if let Stream::Tcp(tcp) = peer {
        let buffer = tcp.write_buffer_mut();
        if buffer.is_empty() {
            // capacity() can be zero after advance() while the original large
            // allocation is still retained. Drop the empty owner itself.
            *buffer = BytesMut::new();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{message, Clipboard};
    use hbb_common::{sodiumoxide::crypto::secretbox::Key, tcp::FramedStream, tokio};

    fn message(length: usize) -> Message {
        let mut message = Message::new();
        message.set_clipboard(Clipboard {
            content: Bytes::from(vec![0x5a; length]),
            ..Default::default()
        });
        message
    }

    #[test]
    fn parsed_image_keeps_received_storage_without_a_body_copy() {
        let original = message(4 * 1024 * 1024);
        let wire = Bytes::from(original.write_to_bytes().unwrap());
        let start = wire.as_ptr() as usize;
        let end = start + wire.len();
        let parsed = decode(wire).unwrap();
        assert_eq!(parsed, original);
        let Some(message::Union::Clipboard(image)) = parsed.union else { panic!() };
        let data = image.content.as_ptr() as usize;
        assert!(data >= start && data + image.content.len() <= end);
        assert_eq!(image.content.as_ref(), vec![0x5a; 4 * 1024 * 1024]);
        let mut malformed = original.write_to_bytes().unwrap();
        malformed.pop();
        assert!(decode(malformed.into()).is_err());
    }

    #[tokio::test]
    async fn flushed_encrypted_image_then_small_message_preserve_wire_contents() {
        let (left, right) = tokio::io::duplex(64 * 1024);
        let address = "127.0.0.1:12345".parse().unwrap();
        let mut sender = Stream::Tcp(FramedStream::from(left, address));
        let mut receiver = Stream::Tcp(FramedStream::from(right, address));
        let key = Key::from_slice(&[7; 32]).unwrap();
        sender.set_key(key.clone());
        receiver.set_key(key);
        let reader = tokio::spawn(async move {
            for length in [4 * 1024 * 1024, 17] {
                let wire = receiver.next().await.unwrap().unwrap();
                assert_eq!(decode(wire.freeze()).unwrap(), message(length));
            }
        });
        let large = message(4 * 1024 * 1024);
        // An incomplete flush must retain every pending byte.
        let Stream::Tcp(tcp) = &mut sender else { panic!() };
        tcp.write_buffer_mut().extend_from_slice(b"pending");
        release_large_write_buffer(&mut sender, &large);
        let Stream::Tcp(tcp) = &mut sender else { panic!() };
        assert_eq!(tcp.write_buffer().as_ref(), b"pending");
        tcp.write_buffer_mut().clear();
        sender.send(&large).await.unwrap();
        release_large_write_buffer(&mut sender, &large);
        let Stream::Tcp(tcp) = &sender else { panic!() };
        assert!(tcp.write_buffer().is_empty());
        assert_eq!(tcp.write_buffer().capacity(), 0);
        sender.send(&message(17)).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(3), reader).await.unwrap().unwrap();
    }
}
