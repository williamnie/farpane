    #[test]
    fn native_approval_snapshot_and_commands_are_recoverable_and_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("approval-command-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };

        let (pending, mut approve_receiver) = pending_approval_fixture(
            "approval-command-host:7",
            7,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(pending),
            NativeApprovalStartResult::Accepted
        );
        let snapshot = host.snapshot_json();
        assert_eq!(snapshot["schemaVersion"], SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(snapshot["authenticatedConnectionCount"], 0);
        assert_eq!(
            snapshot["pendingApproval"]["connectionId"],
            "approval-command-host:7"
        );
        assert_eq!(
            snapshot["pendingApproval"]["remoteMetadataTrust"],
            "untrusted"
        );

        let approve = json!({
            "commandId": "approval-approve",
            "name": "approveConnection",
            "connectionId": "approval-command-host:7",
        });
        assert_eq!(
            handle_command(&mut host, "approval-approve", "approveConnection", &approve,),
            RDN_HOST_OK
        );
        assert!(matches!(
            approve_receiver.try_recv(),
            Ok(crate::ipc::Data::Authorize)
        ));
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert_eq!(
            handle_command(&mut host, "approval-late", "approveConnection", &approve,),
            RDN_HOST_ERR_APPROVAL_FINALIZED
        );

        let malformed = json!({
            "commandId": "approval-malformed",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
            "ignored": true,
        });
        assert_eq!(
            handle_command(
                &mut host,
                "approval-malformed",
                "rejectConnection",
                &malformed,
            ),
            RDN_HOST_ERR_VALIDATION
        );

        let (reject_pending, mut reject_receiver) = pending_approval_fixture(
            "approval-command-host:8",
            8,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(reject_pending),
            NativeApprovalStartResult::Accepted
        );
        let reject = json!({
            "commandId": "approval-reject",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
        });
        assert_eq!(
            handle_command(&mut host, "approval-reject", "rejectConnection", &reject,),
            RDN_HOST_OK
        );
        assert!(matches!(
            reject_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (expired_pending, mut expired_receiver) = pending_approval_fixture(
            "approval-command-host:9",
            9,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(expired_pending),
            NativeApprovalStartResult::Accepted
        );
        let expired = json!({
            "commandId": "approval-expired",
            "name": "approveConnection",
            "connectionId": "approval-command-host:9",
        });
        assert_eq!(
            handle_command(&mut host, "approval-expired", "approveConnection", &expired,),
            RDN_HOST_ERR_APPROVAL_EXPIRED
        );
        assert!(matches!(
            expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (snapshot_expired, mut snapshot_expired_receiver) = pending_approval_fixture(
            "approval-command-host:10",
            10,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(snapshot_expired),
            NativeApprovalStartResult::Accepted
        );
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert!(matches!(
            snapshot_expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let encoded_events = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded_events.contains("approval-approved"));
        assert!(encoded_events.contains("approval-rejected"));
        assert!(encoded_events.contains("approval-expired"));
        assert!(!encoded_events.contains("decision_sender"));
        unbind_media_host();
    }

    fn submit_h264_access_unit(
        host: &mut RdnHost,
        route: &NativeMediaRoute,
        instance_id: &CString,
        pts_us: u64,
        keyframe: bool,
    ) -> i32 {
        let data = [pts_us as u8];
        let flags = if keyframe {
            MEDIA_FLAG_KEYFRAME | MEDIA_FLAG_PARAMETER_SETS
        } else {
            0
        };
        let access_unit = RdnHostEncodedAccessUnit {
            abi_version: HOST_MEDIA_ABI_VERSION,
            host_instance_id: instance_id.as_ptr(),
            connection_epoch: route.connection_epoch,
            codec_epoch: route.codec_epoch,
            display_id: route.display_id,
            display_revision: route.display_revision,
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            flags,
            pts_us,
            data: data.as_ptr(),
            length: data.len(),
        };
        unsafe { rdn_host_media_submit_access_unit(host, &access_unit) }
    }

    fn media_packet(pts_us: u64, keyframe: bool) -> NativeMediaAccessUnit {
        NativeMediaAccessUnit {
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            pts_us,
            keyframe,
            has_parameter_sets: keyframe,
            data: vec![pts_us as u8],
        }
    }

    #[test]
    fn rejects_namespace_components_that_could_escape_directories() {
        assert!(valid_namespace_component("FarPaneHost"));
        assert!(valid_namespace_component("io.rustdesknative"));
        assert!(!valid_namespace_component(""));
        assert!(!valid_namespace_component("../evil"));
        assert!(!valid_namespace_component("a/b"));
        assert!(!valid_namespace_component("a:b"));
        assert!(!valid_namespace_component(&"x".repeat(MAX_NAME_BYTES + 1)));
    }

    #[test]
    fn command_envelope_bounds_are_enforced() {
        assert_eq!(parse_envelope(b""), Err(RDN_HOST_ERR_VALIDATION));
        assert_eq!(
            parse_envelope(&vec![b' '; MAX_ENVELOPE_BYTES + 1]),
            Err(RDN_HOST_ERR_VALIDATION)
        );
        assert!(parse_envelope(b"{\"commandId\":\"1\",\"name\":\"enableHost\"}").is_ok());
        assert_eq!(parse_envelope(b"{not json"), Err(RDN_HOST_ERR_VALIDATION));
    }

    #[test]
    fn media_milestone_payload_is_sanitized_and_fail_closed() {
        let (_, receiver) = sync_channel(1);
        let route = NativeMediaRoute {
            connection_epoch: 7,
            codec_epoch: 9,
            display_id: 0,
            display_revision: 3,
            codec: MEDIA_CODEC_H264,
            receiver,
            queue_telemetry: Arc::new(NativeMediaQueueTelemetry::default()),
            writer_telemetry: Arc::new(NativeMediaWriterTelemetry::default()),
            network_telemetry: Arc::new(NativeMediaNetworkTelemetry::default()),
            transport_telemetry: Arc::new(NativeMediaTransportTelemetry::default()),
        };
        let packet = NativeMediaPacketMetadata {
            framing: MEDIA_FRAMING_AVCC,
            pts_us: 42_999,
            keyframe: true,
            has_parameter_sets: true,
        };
        let payload = native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketAcknowledged,
            packet,
            1,
        )
        .unwrap();
        assert_eq!(payload["kind"], "firstPacketAcknowledged");
        assert_eq!(payload["codec"], "h264");
        assert_eq!(payload["framing"], "avcc");
        assert_eq!(payload["subscriberCount"], 1);
        let encoded = serde_json::to_string(&payload).unwrap();
        for forbidden in ["peerId", "data", "password", "server"] {
            assert!(!encoded.contains(forbidden));
        }
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketDispatched,
            packet,
            0,
        )
        .is_none());
        let invalid_packet = NativeMediaPacketMetadata {
            framing: 99,
            ..packet
        };
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::RefreshKeyframeDispatched,
            invalid_packet,
            1,
        )
        .is_none());
    }

    #[test]
    fn full_media_queue_rejects_newest_without_evicting_encoded_packets() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert!(
                try_enqueue_native_media(&sender, &telemetry, media_packet(pts_us, keyframe))
                    .is_ok()
            );
        }
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(400, false))
                .expect_err("a full encoded queue must reject the new packet");
        assert_eq!(reason, NativeMediaQueueDropReason::NetworkBackpressure);
        assert_eq!(rejected.pts_us, 400);
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = receiver.try_recv().expect("queued packet");
                telemetry.record_dequeued();
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![100, 200, 300]
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.keyframe)
                .collect::<Vec<_>>(),
            vec![true, false, false]
        );
    }

    #[test]
    fn public_access_unit_api_reports_saturation_then_accepts_replacement_idr() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let mut host = ready_test_host("queue-saturation-host");
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
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route should use the production bounded queue");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();

        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert_eq!(
                submit_h264_access_unit(&mut host, &route, &instance_id, pts_us, keyframe),
                RDN_HOST_OK
            );
        }
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, false),
            RDN_HOST_ERR_BACKPRESSURE
        );

        let first = route.receiver.try_recv().expect("first queued IDR");
        native_media_record_dequeued(&route);
        assert_eq!(first.pts_us, 100);
        assert!(first.keyframe);
        assert!(first.has_parameter_sets);

        // A rejected submit must not advance route state. Reusing its PTS for
        // the replacement generation's IDR is therefore valid once one queue
        // slot is available.
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, true),
            RDN_HOST_OK
        );
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = route.receiver.try_recv().expect("retained queued packet");
                native_media_record_dequeued(&route);
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![200, 300, 400]
        );
        assert!(!retained[0].keyframe);
        assert!(!retained[1].keyframe);
        assert!(retained[2].keyframe);
        assert!(retained[2].has_parameter_sets);
    }

    #[test]
    fn disconnected_media_queue_classifies_shutdown_and_returns_packet() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        drop(receiver);

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(500, true))
                .expect_err("a disconnected queue must reject the packet");
        assert_eq!(reason, NativeMediaQueueDropReason::Shutdown);
        assert_eq!(rejected.pts_us, 500);
        assert!(rejected.keyframe);
        assert!(rejected.has_parameter_sets);
        assert_eq!(telemetry.snapshot(), NativeMediaQueueSnapshot::default());
    }

    #[test]
    fn media_queue_payload_is_sanitized_and_bounded() {
        let payload = native_media_queue_payload(
            "routeStopped",
            7,
            9,
            0,
            3,
            NativeMediaQueueSnapshot {
                current_depth: 1,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            },
        );
        assert_eq!(payload["kind"], "routeStopped");
        assert_eq!(payload["connectionEpoch"], 7);
        assert_eq!(payload["codecEpoch"], 9);
        assert_eq!(payload["displayId"], 0);
        assert_eq!(payload["displayRevision"], 3);
        assert_eq!(payload["currentDepth"], 1);
        assert_eq!(payload["maximumDepth"], MEDIA_QUEUE_CAPACITY);
        assert_eq!(payload["capacity"], MEDIA_QUEUE_CAPACITY);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn writer_timing_aggregates_only_route_scoped_wall_measurements() {
        let telemetry = NativeMediaWriterTelemetry::default();
        telemetry.record(
            0,
            Duration::from_micros(99),
            Duration::from_millis(99),
            false,
        );
        telemetry.record(2, Duration::from_micros(15), Duration::from_millis(2), true);
        telemetry.record(
            1,
            Duration::from_micros(10),
            Duration::from_millis(3),
            false,
        );
        let snapshot = NativeMediaWriterSnapshot {
            cycles: 2,
            subscriber_dispatches: 3,
            dispatch_wall_total_us: 25,
            maximum_dispatch_wall_us: 15,
            confirmation_wait_total_us: 5_000,
            maximum_confirmation_wait_us: 3_000,
            completed_confirmations: 1,
            timed_out_confirmations: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_writer_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["cycles"], 2);
        assert_eq!(payload["subscriberDispatches"], 3);
        assert_eq!(payload["dispatchWallTotalUs"], 25);
        assert_eq!(payload["maximumConfirmationWaitUs"], 3_000);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn network_payload_preserves_sample_availability_and_count_bounds() {
        let telemetry = NativeMediaNetworkTelemetry::default();
        assert!(telemetry.record(3, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(1, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(3, 2, 0, 0, 0, Some(180), None));
        let snapshot = NativeMediaNetworkSnapshot {
            subscriber_count: 3,
            qos_subscriber_count: 2,
            delay_sampled_subscribers: 2,
            rtt_sampled_subscribers: 1,
            response_delayed_subscribers: 1,
            worst_network_delay_ms: Some(180),
            worst_rtt_ms: Some(42),
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_network_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 3);
        assert_eq!(payload["qosSubscriberCount"], 2);
        assert_eq!(payload["delaySampledSubscribers"], 2);
        assert_eq!(payload["rttSampledSubscribers"], 1);
        assert_eq!(payload["responseDelayedSubscribers"], 1);
        assert_eq!(payload["worstNetworkDelayMs"], 180);
        assert_eq!(payload["worstRttMs"], 42);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn transport_payload_preserves_unknown_and_rejects_inconsistent_counts() {
        let telemetry = NativeMediaTransportTelemetry::default();
        assert!(telemetry.record(4, 2, 1, 1));
        assert!(!telemetry.record(4, 2, 1, 0));
        let snapshot = NativeMediaTransportSnapshot {
            subscriber_count: 4,
            direct_subscribers: 2,
            relay_subscribers: 1,
            unknown_subscribers: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_transport_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 4);
        assert_eq!(payload["directSubscribers"], 2);
        assert_eq!(payload["relaySubscribers"], 1);
        assert_eq!(payload["unknownSubscribers"], 1);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn route_stop_emits_final_queue_sample_before_stop_control() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("queue-event-host");
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
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 100, true),
            RDN_HOST_OK
        );
        native_media_record_writer_cycle(
            &route,
            1,
            Duration::from_micros(10),
            Duration::from_millis(2),
            true,
        );
        native_media_report_queue_depth(&route);
        native_media_report_writer_timing(&route);
        native_media_report_network(&route, 1, 1, 1, 1, 0, Some(25), Some(20));
        native_media_report_transport(&route, 1, 0, 1, 0);
        native_media_end_route(&route);

        let events = events.lock().unwrap();
        let tail = &events[events.len() - 9..];
        assert_eq!(tail[0]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[0]["payload"]["kind"], "sample");
        assert_eq!(tail[1]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[1]["payload"]["kind"], "sample");
        assert_eq!(tail[2]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[2]["payload"]["kind"], "sample");
        assert_eq!(tail[3]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[3]["payload"]["kind"], "sample");
        assert_eq!(tail[4]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[4]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[4]["payload"]["currentDepth"], 1);
        assert_eq!(tail[4]["payload"]["maximumDepth"], 1);
        assert_eq!(tail[5]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[5]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[5]["payload"]["cycles"], 1);
        assert_eq!(tail[6]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[6]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[6]["payload"]["worstRttMs"], 20);
        assert_eq!(tail[7]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[7]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[7]["payload"]["relaySubscribers"], 1);
        assert_eq!(tail[8]["eventType"], "mediaControl");
        assert_eq!(tail[8]["payload"]["command"], "stopCapture");
    }
