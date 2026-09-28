    #[test]
    fn display_reconfigure_provenance_is_exact_and_consumed_once() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("display-provenance-host");
        host.callbacks.on_event = Some(collect_test_event);
        host.callbacks.context = &events as *const _ as *mut c_void;
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }

        let previous = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("initial route");
        assert_eq!(previous.display_revision, 1);
        native_media_mark_display_reconfigure(&previous).expect("display marker");
        assert!(native_media_mark_display_reconfigure(&previous).is_err());
        native_media_end_route(&previous);

        let replacement = native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
            .expect("display replacement route");
        assert_eq!(replacement.display_revision, 2);
        assert!(replacement.connection_epoch > previous.connection_epoch);
        assert!(replacement.codec_epoch > previous.codec_epoch);

        native_media_end_route(&replacement);
        let generic_retry =
            native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
                .expect("generic retry route");
        assert_eq!(generic_retry.display_revision, 2);

        let events = events.lock().unwrap();
        let started = events
            .iter()
            .filter(|event| event["eventType"] == "mediaDisplayReconfigureStarted")
            .collect::<Vec<_>>();
        assert_eq!(started.len(), 1);
        let marker = &started[0]["payload"];
        assert_eq!(marker["displayId"], 0);
        assert_eq!(marker["previousDisplayRevision"], 1);
        assert_eq!(marker["previousConnectionEpoch"], previous.connection_epoch);
        assert_eq!(marker["previousCodecEpoch"], previous.codec_epoch);
        assert!(marker["displayReconfigureGeneration"].as_u64().unwrap() > 0);

        let replacement_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == replacement.connection_epoch
                    && matches!(
                        event["payload"]["command"].as_str(),
                        Some("startCapture" | "reconfigure")
                    )
            })
            .collect::<Vec<_>>();
        assert_eq!(replacement_controls.len(), 2);
        for control in replacement_controls {
            assert_eq!(control["payload"]["displayRevision"], 2);
            assert_eq!(
                control["payload"]["displayReconfigure"]["displayReconfigureGeneration"],
                marker["displayReconfigureGeneration"]
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousDisplayRevision"],
                1
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousConnectionEpoch"],
                previous.connection_epoch
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousCodecEpoch"],
                previous.codec_epoch
            );
        }

        let generic_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == generic_retry.connection_epoch
            })
            .collect::<Vec<_>>();
        assert_eq!(generic_controls.len(), 2);
        assert!(generic_controls
            .iter()
            .all(|event| { event["payload"].get("displayReconfigure").is_none() }));
    }
