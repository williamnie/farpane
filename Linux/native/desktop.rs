//! User-session SNI/notifications. No toolkit, passwords or approval commands.
use dbus::{
    arg::{PropMap, Variant},
    blocking::Connection,
    channel::{MatchingReceiver, Sender},
    message::MatchRule,
    Message,
};
use dbus_crossroads::{Crossroads, IfaceToken};
use farpane_protocol::DesktopStatus;
use hbb_common::{bail, config::Config, ResultType};
use std::{
    collections::HashMap,
    sync::{
        mpsc::{self, SyncSender},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

#[path = "desktop_menu.rs"]
mod menu;
const AGENT: &str = "org.farpane.FarPane.Agent";
const GUI: &str = "org.farpane.FarPane";
const NOTIFY: &str = "org.freedesktop.Notifications";
const NOTIFY_PATH: &str = "/org/freedesktop/Notifications";
const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/MenuBar";
const ICON: &str = "org.farpane.FarPane";
const WATCHERS: [&str; 2] = [
    "org.kde.StatusNotifierWatcher",
    "org.freedesktop.StatusNotifierWatcher",
];
const ITEM_IFACES: [&str; 2] = [
    "org.kde.StatusNotifierItem",
    "org.freedesktop.StatusNotifierItem",
];
const CALL_TIMEOUT: Duration = Duration::from_millis(500);
type Pixmaps = Vec<(i32, i32, Vec<u8>)>;
static STATUS: OnceLock<Mutex<DesktopStatus>> = OnceLock::new();
pub fn status() -> DesktopStatus {
    STATUS.get_or_init(Default::default).lock().unwrap().clone()
}
fn publish(status: DesktopStatus) {
    let mut old = STATUS.get_or_init(Default::default).lock().unwrap();
    if *old != status {
        *old = status;
        super::control::changed();
    }
}
pub fn start() {
    if unsafe { hbb_common::libc::geteuid() } == 0
        || unsafe { hbb_common::libc::getuid() != hbb_common::libc::geteuid() }
        || std::env::var("XDG_SESSION_CLASS")
            .is_ok_and(|v| !matches!(v.as_str(), "user" | "user-early"))
        || std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none()
    {
        publish(DesktopStatus {
            detail: "当前会话没有可用的用户桌面总线".into(),
            ..Default::default()
        });
        return;
    }
    if std::thread::Builder::new()
        .name("farpane-desktop".into())
        .spawn(|| loop {
            if run().is_err() {
                publish(DesktopStatus {
                    detail: "桌面服务暂不可用；请从应用菜单打开 FarPane".into(),
                    ..Default::default()
                });
            }
            std::thread::sleep(Duration::from_secs(5));
        })
        .is_err()
    {
        publish(DesktopStatus {
            detail: "桌面集成线程未启动".into(),
            ..Default::default()
        });
    }
}
#[derive(Clone)]
pub(super) enum UiAction {
    Home,
    Connections,
    Menu,
}
#[derive(Clone)]
pub(super) struct Item {
    model: Arc<Mutex<Model>>,
    pub(super) actions: SyncSender<UiAction>,
}
struct Model {
    status: String,
    description: String,
    pixmaps: Pixmaps,
}
enum NoticeEvent {
    Action(String, u32, String),
    Token(String, u32, String),
    Closed(String, u32),
    Owners,
}
struct Notice {
    id: Option<u32>,
    attempted: bool,
    token: Option<String>,
}
fn register_item(cr: &mut Crossroads, interface: &'static str) -> IfaceToken<Item> {
    cr.register(interface, |b| {
        b.property::<String, _>("Category")
            .get(|_, _: &mut Item| Ok("Communications".into()));
        b.property::<String, _>("Id")
            .get(|_, _: &mut Item| Ok("FarPane".into()));
        b.property::<String, _>("Title")
            .get(|_, _: &mut Item| Ok("FarPane".into()));
        b.property::<String, _>("Status")
            .get(|_, d: &mut Item| Ok(d.model.lock().unwrap().status.clone()));
        b.property::<u32, _>("WindowId")
            .get(|_, _: &mut Item| Ok(0));
        b.property::<String, _>("IconName")
            .get(|_, _: &mut Item| Ok(ICON.into()));
        b.property::<String, _>("AttentionIconName")
            .get(|_, _: &mut Item| Ok(ICON.into()));
        b.property::<String, _>("OverlayIconName")
            .get(|_, _: &mut Item| Ok(String::new()));
        b.property::<String, _>("AttentionMovieName")
            .get(|_, _: &mut Item| Ok(String::new()));
        b.property::<Pixmaps, _>("IconPixmap")
            .get(|_, d: &mut Item| Ok(d.model.lock().unwrap().pixmaps.clone()));
        b.property::<Pixmaps, _>("AttentionIconPixmap")
            .get(|_, d: &mut Item| Ok(d.model.lock().unwrap().pixmaps.clone()));
        b.property::<Pixmaps, _>("OverlayIconPixmap")
            .get(|_, _: &mut Item| Ok(vec![]));
        b.property::<(String, Pixmaps, String, String), _>("ToolTip")
            .get(|_, d: &mut Item| {
                Ok((
                    ICON.into(),
                    vec![],
                    "FarPane".into(),
                    d.model.lock().unwrap().description.clone(),
                ))
            });
        b.property::<bool, _>("ItemIsMenu")
            .get(|_, _: &mut Item| Ok(false));
        b.property::<dbus::Path<'static>, _>("Menu")
            .get(|_, _: &mut Item| Ok(MENU_PATH.into()));
        for name in [
            "NewTitle",
            "NewIcon",
            "NewAttentionIcon",
            "NewOverlayIcon",
            "NewToolTip",
        ] {
            b.signal::<(), _>(name, ());
        }
        b.signal::<(String,), _>("NewStatus", ("status",));
        for (name, action) in [
            ("Activate", UiAction::Home),
            ("SecondaryActivate", UiAction::Connections),
            ("ContextMenu", UiAction::Menu),
        ] {
            b.method(
                name,
                ("x", "y"),
                (),
                move |_, d: &mut Item, (_, _): (i32, i32)| {
                    let _ = d.actions.try_send(action.clone());
                    Ok(())
                },
            );
        }
        b.method(
            "Scroll",
            ("delta", "orientation"),
            (),
            |_, _: &mut Item, (_, _): (i32, String)| Ok(()),
        );
    })
}
fn owner(c: &Connection, name: &str) -> Option<String> {
    let result: Result<(String,), _> = c
        .with_proxy(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            CALL_TIMEOUT,
        )
        .method_call("org.freedesktop.DBus", "GetNameOwner", (name,));
    result.ok().map(|v| v.0)
}
fn close_notice(c: &Connection, owner: &str, id: u32) {
    if let Ok(mut m) = Message::new_method_call(owner, NOTIFY_PATH, NOTIFY, "CloseNotification") {
        m = m.append1(id);
        m.set_no_reply(true);
        let _ = c.send(m);
    }
}
fn text(value: &str, markup: bool) -> String {
    let plain = value
        .chars()
        .filter(|c| !c.is_control())
        .take(128)
        .collect::<String>();
    if markup {
        plain
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    } else {
        plain
    }
}
fn activate(c: &Connection, action: UiAction, token: Option<String>) {
    let mut platform = PropMap::new();
    if let Some(token) = token {
        // GTK handles platform data when activating its application window.
        platform.insert("activation-token".into(), Variant(Box::new(token.clone())));
        platform.insert("desktop-startup-id".into(), Variant(Box::new(token)));
    }
    let action = match action {
        UiAction::Home => "show-home",
        UiAction::Connections => "show-connections",
        UiAction::Menu => "tray-menu",
    };
    let _: Result<(), _> = c
        .with_proxy(GUI, "/org/farpane/FarPane", Duration::from_secs(3))
        .method_call(
            "org.freedesktop.Application",
            "ActivateAction",
            (action, Vec::<Variant<String>>::new(), platform),
        );
}
fn run() -> ResultType<()> {
    use dbus::blocking::stdintf::org_freedesktop_dbus::RequestNameReply;
    let c = Connection::new_session()?;
    if c.request_name(AGENT, false, false, true)? != RequestNameReply::PrimaryOwner {
        bail!("Desktop name already owned");
    }
    for prefix in [
        "org.kde.StatusNotifierItem",
        "org.freedesktop.StatusNotifierItem",
    ] {
        if c.request_name(
            format!("{prefix}-{}-1", std::process::id()),
            false,
            false,
            true,
        )? != RequestNameReply::PrimaryOwner
        {
            bail!("Tray name already owned");
        }
    }
    let image = image::load_from_memory(include_bytes!("desktop-icon.png"))?
        .thumbnail_exact(32, 32)
        .to_rgba8();
    let mut argb = Vec::with_capacity(32 * 32 * 4);
    for p in image.pixels() {
        argb.extend_from_slice(&[p[3], p[0], p[1], p[2]]);
    }
    drop(image);
    let model = Arc::new(Mutex::new(Model {
        status: "Passive".into(),
        description: "等待后台状态".into(),
        pixmaps: vec![(32, 32, argb)],
    }));
    let (actions, rx) = mpsc::sync_channel(8);
    let item = Item {
        model: model.clone(),
        actions,
    };
    let mut cr = Crossroads::new();
    let kde = register_item(&mut cr, ITEM_IFACES[0]);
    let fd = register_item(&mut cr, ITEM_IFACES[1]);
    let menu = menu::register(&mut cr);
    cr.insert(ITEM_PATH, &[kde, fd], item.clone());
    cr.insert(MENU_PATH, &[menu], item);
    c.start_receive(
        MatchRule::new_method_call(),
        Box::new(move |msg, c| {
            let _ = cr.handle_message(msg, c);
            true
        }),
    );
    let (events, erx) = mpsc::sync_channel(64);
    for member in ["ActionInvoked", "ActivationToken", "NotificationClosed"] {
        let rule = MatchRule::new_signal(NOTIFY, member);
        c.add_match_no_cb(&rule.match_str())?;
        let events = events.clone();
        c.start_receive(
            rule,
            Box::new(move |msg, _| {
                let Some(sender) = msg.sender().map(|s| s.to_string()) else {
                    return true;
                };
                let event = if member == "NotificationClosed" {
                    msg.get1::<u32>().map(|id| NoticeEvent::Closed(sender, id))
                } else {
                    let (id, value) = msg.get2::<u32, &str>();
                    match (id, value) {
                        (Some(id), Some(value)) if value.len() <= 2048 => {
                            Some(if member == "ActivationToken" {
                                NoticeEvent::Token(sender, id, value.into())
                            } else {
                                NoticeEvent::Action(sender, id, value.into())
                            })
                        }
                        _ => None,
                    }
                };
                if let Some(event) = event {
                    let _ = events.try_send(event);
                }
                true
            }),
        );
    }
    let mut rule = MatchRule::new_signal("org.freedesktop.DBus", "NameOwnerChanged");
    rule.sender = Some("org.freedesktop.DBus".into());
    c.add_match_no_cb(&rule.match_str())?;
    c.start_receive(
        rule,
        Box::new(move |msg, _| {
            if msg
                .get1::<&str>()
                .is_some_and(|n| n == NOTIFY || WATCHERS.contains(&n))
            {
                let _ = events.try_send(NoticeEvent::Owners);
            }
            true
        }),
    );
    let mut notify_owner = None::<String>;
    let mut watcher = None::<(String, String)>;
    let mut notifications = false;
    let mut notification_actions = false;
    let mut notification_markup = false;
    let mut registered = false;
    let mut notices = HashMap::<i32, Notice>::new();
    let mut dirty = true;
    let mut refresh = Instant::now();
    let mut services = Instant::now();
    let mut last_activation = None::<Instant>;
    loop {
        c.process(Duration::from_millis(200))?;
        let mut action = rx.try_iter().last().map(|a| (a, None));
        for event in erx.try_iter() {
            match event {
                NoticeEvent::Owners => dirty = true,
                NoticeEvent::Token(sender, id, token)
                    if notify_owner.as_deref() == Some(&sender) =>
                {
                    if let Some(notice) = notices.values_mut().find(|n| n.id == Some(id)) {
                        notice.token = Some(token);
                    }
                }
                NoticeEvent::Action(sender, id, key)
                    if notification_actions
                        && notify_owner.as_deref() == Some(&sender)
                        && (key == "review" || key == "default") =>
                {
                    if let Some((&connection, notice)) =
                        notices.iter_mut().find(|(_, n)| n.id == Some(id))
                    {
                        if super::cm::connections()
                            .iter()
                            .any(|p| p.id == connection && !p.authorized)
                        {
                            action = Some((UiAction::Connections, notice.token.take()));
                        }
                    }
                }
                NoticeEvent::Closed(sender, id) if notify_owner.as_deref() == Some(&sender) => {
                    if let Some(notice) = notices.values_mut().find(|n| n.id == Some(id)) {
                        notice.id = None;
                        notice.token = None;
                    }
                }
                _ => {}
            }
        }
        if let Some((action, token)) = action {
            if last_activation.is_none_or(|at| at.elapsed() > Duration::from_millis(500)) {
                last_activation = Some(Instant::now());
                activate(&c, action, token);
            }
        }
        if dirty || services.elapsed() > Duration::from_secs(5) {
            dirty = false;
            services = Instant::now();
            let found = WATCHERS
                .iter()
                .find_map(|name| owner(&c, name).map(|o| (name.to_string(), o)));
            if found != watcher {
                watcher = found;
                registered = false;
            }
            if !registered {
                if let Some((name, owner)) = &watcher {
                    let result: Result<(), _> = c
                        .with_proxy(owner, "/StatusNotifierWatcher", CALL_TIMEOUT)
                        .method_call(
                            name,
                            "RegisterStatusNotifierItem",
                            (format!(
                                "{}-{}-1",
                                if name.starts_with("org.kde") {
                                    ITEM_IFACES[0]
                                } else {
                                    ITEM_IFACES[1]
                                },
                                std::process::id()
                            ),),
                        );
                    registered = result.is_ok();
                }
            }
            let current = owner(&c, NOTIFY);
            if current != notify_owner {
                notify_owner = current;
                notifications = false;
                notification_actions = false;
                notification_markup = false;
                for n in notices.values_mut() {
                    n.id = None;
                    n.attempted = false;
                    n.token = None;
                }
            }
            if !notifications {
                if let Some(owner) = &notify_owner {
                    let caps: Result<(Vec<String>,), _> = c
                        .with_proxy(owner, NOTIFY_PATH, CALL_TIMEOUT)
                        .method_call(NOTIFY, "GetCapabilities", ());
                    if let Ok((caps,)) = caps {
                        notifications = true;
                        notification_actions = caps.iter().any(|s| s == "actions");
                        notification_markup = caps.iter().any(|s| s == "body-markup");
                    }
                }
            }
            publish(DesktopStatus {
                connected: true,
                tray_registered: registered,
                notifications_available: notifications,
                notification_actions,
                detail: if !notifications {
                    "当前桌面没有可用通知服务，可从应用菜单查看请求"
                } else if !notification_actions {
                    "通知不支持操作按钮，可从 FarPane 查看请求"
                } else if !registered {
                    "通知可用；当前桌面未提供托盘，仍可从应用菜单打开"
                } else {
                    "通知可用；托盘项已注册"
                }
                .into(),
            });
        }
        if refresh.elapsed() < Duration::from_millis(500) {
            continue;
        }
        refresh = Instant::now();
        let connections = super::cm::connections();
        let pending: Vec<_> = connections
            .iter()
            .filter(|p| !p.authorized)
            .take(64)
            .collect();
        notices.retain(|id, n| {
            if pending.iter().any(|p| p.id == *id) {
                return true;
            }
            if let (Some(owner), Some(id)) = (&notify_owner, n.id) {
                close_notice(&c, owner, id);
            }
            false
        });
        let enabled = Config::get_option("stop-service") != "Y";
        let status = if !pending.is_empty() {
            "NeedsAttention"
        } else if enabled {
            "Active"
        } else {
            "Passive"
        };
        let description = if !pending.is_empty() {
            format!("{} 个请求等待批准", pending.len())
        } else if !connections.is_empty() {
            format!("{} 个连接正在访问本机", connections.len())
        } else if enabled {
            "等待设备连接".into()
        } else {
            "本机被控已关闭".into()
        };
        {
            let mut model = model.lock().unwrap();
            for interface in ITEM_IFACES {
                if model.status != status {
                    let _ = c.send(
                        Message::new_signal(ITEM_PATH, interface, "NewStatus")
                            .unwrap()
                            .append1(status),
                    );
                }
                if model.description != description {
                    let _ =
                        c.send(Message::new_signal(ITEM_PATH, interface, "NewToolTip").unwrap());
                }
            }
            model.status = status.into();
            model.description = description;
        }
        for p in &pending {
            notices.entry(p.id).or_insert(Notice {
                id: None,
                attempted: false,
                token: None,
            });
        }
        if notifications {
            if let Some(p) = pending
                .iter()
                .find(|p| notices.get(&p.id).is_some_and(|n| !n.attempted))
            {
                let notice = notices.get_mut(&p.id).unwrap();
                notice.attempted = true;
                let mut hints = PropMap::new();
                hints.insert("desktop-entry".into(), Variant(Box::new(GUI.to_string())));
                hints.insert("urgency".into(), Variant(Box::new(1u8)));
                hints.insert("suppress-sound".into(), Variant(Box::new(true)));
                let body = format!(
                    "{} · {}\n请在 FarPane 中批准；无人处理将自动拒绝。",
                    text(&p.name, notification_markup),
                    text(&p.peer, notification_markup)
                );
                let result: Result<(u32,), _> = c
                    .with_proxy(notify_owner.as_ref().unwrap(), NOTIFY_PATH, CALL_TIMEOUT)
                    .method_call(
                        NOTIFY,
                        "Notify",
                        (
                            "FarPane",
                            0u32,
                            ICON,
                            "有设备请求连接本机",
                            body,
                            if notification_actions {
                                vec!["default", "查看请求", "review", "查看请求"]
                            } else {
                                vec![]
                            },
                            hints,
                            30_000i32,
                        ),
                    );
                if let Ok((id,)) = result {
                    if id != 0 {
                        notice.id = Some(id);
                    }
                }
            }
        }
    }
}
