//! Reconnect a revoked native input transport without replaying failed input.
use crate::ipc::{self, Connection, Data};
use hbb_common::{anyhow::anyhow, log, tokio, ResultType};
use std::time::{Duration, Instant};

pub async fn send(
    connection: &mut Connection,
    data: &Data,
    retry: &mut Instant,
    postfix: &str,
) -> ResultType<()> {
    let result = match tokio::time::timeout(Duration::from_millis(100), connection.send(data)).await
    {
        Ok(result) => result,
        Err(_) => Err(anyhow!("Native input transport timed out")),
    };
    if result.is_err() && retry.elapsed() >= Duration::from_millis(500) {
        *retry = Instant::now();
        match ipc::connect(100, postfix).await {
            Ok(new) => *connection = new,
            Err(error) => log::trace!("Native input transport is not ready: {error}"),
        }
    }
    // Never retry the failed action: it may already have been applied before
    // a transport failure, or belong to a desktop that has since disappeared.
    result
}

pub fn record(result: ResultType<()>) {
    if let Err(error) = result {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            warn,
            "Native input was dropped while its service was unavailable: {error}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::futures::StreamExt;
    #[test]
    fn lost_transport_reconnects_but_never_replays_the_failed_action() {
        let postfix = format!("_native_retry_{}", std::process::id());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let mut incoming = ipc::new_listener(&postfix).await.unwrap();
            let mut client = ipc::connect(100, &postfix).await.unwrap();
            let server = incoming.next().await.unwrap().unwrap();
            drop(server);
            let mut retry = Instant::now() - Duration::from_secs(1);
            // The closed AF_UNIX peer reports a broken transport, not an
            // application acknowledgement. The helper opens a fresh socket.
            assert!(send(&mut client, &Data::Empty, &mut retry, &postfix)
                .await
                .is_err());
            let mut replacement = Connection::new(incoming.next().await.unwrap().unwrap());
            assert!(replacement.next_timeout2(30).await.is_none());
            send(&mut client, &Data::Empty, &mut retry, &postfix)
                .await
                .unwrap();
            assert!(matches!(
                replacement.next_timeout(100).await.unwrap(),
                Some(Data::Empty)
            ));
            drop(replacement);
            assert!(send(&mut client, &Data::Empty, &mut retry, &postfix)
                .await
                .is_err());
            assert!(
                tokio::time::timeout(Duration::from_millis(30), incoming.next())
                    .await
                    .is_err()
            );
        });
        std::fs::remove_file(hbb_common::config::Config::ipc_path(&postfix)).unwrap();
    }
}
