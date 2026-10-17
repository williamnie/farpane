//! Bounded, static DBusMenu. It can open UI, never grant remote permissions.
use super::{Item, UiAction};
use dbus::{
    arg::{PropMap, RefArg, Variant},
    MethodErr,
};
use dbus_crossroads::{Crossroads, IfaceToken};

type Layout = (i32, PropMap, Vec<Variant<Box<dyn RefArg>>>);
fn properties(id: i32, names: &[String]) -> Result<PropMap, MethodErr> {
    if !(0..=2).contains(&id) || names.len() > 32 {
        return Err(MethodErr::failed("Invalid menu request"));
    }
    let mut props = PropMap::new();
    if id == 0 {
        props.insert(
            "children-display".into(),
            Variant(Box::new("submenu".to_string())),
        );
    } else {
        props.insert(
            "label".into(),
            Variant(Box::new(
                if id == 1 {
                    "打开 FarPane"
                } else {
                    "本机连接与权限"
                }
                .to_string(),
            )),
        );
        props.insert("enabled".into(), Variant(Box::new(true)));
        props.insert("visible".into(), Variant(Box::new(true)));
    }
    if !names.is_empty() {
        props.retain(|k, _| names.contains(k));
    }
    Ok(props)
}
fn layout(id: i32, depth: i32, names: &[String]) -> Result<Layout, MethodErr> {
    let props = properties(id, names)?;
    let children = if id == 0 && depth != 0 {
        vec![
            Variant(Box::new(layout(1, 0, names)?) as Box<dyn RefArg>),
            Variant(Box::new(layout(2, 0, names)?) as Box<dyn RefArg>),
        ]
    } else {
        vec![]
    };
    Ok((id, props, children))
}
fn event(item: &Item, id: i32, event: &str) -> Result<(), MethodErr> {
    if !(0..=2).contains(&id) {
        return Err(MethodErr::failed("Unknown menu item"));
    }
    if event == "clicked" && id != 0 {
        let _ = item.actions.try_send(if id == 1 {
            UiAction::Home
        } else {
            UiAction::Connections
        });
    }
    Ok(())
}
pub(super) fn register(cr: &mut Crossroads) -> IfaceToken<Item> {
    cr.register("com.canonical.dbusmenu", |b| {
        b.property::<u32, _>("Version").get(|_, _: &mut Item| Ok(3));
        b.property::<String, _>("Status")
            .get(|_, _: &mut Item| Ok("normal".into()));
        b.property::<String, _>("TextDirection")
            .get(|_, _: &mut Item| Ok("ltr".into()));
        b.property::<Vec<String>, _>("IconThemePath")
            .get(|_, _: &mut Item| Ok(vec![]));
        b.signal::<(u32, i32), _>("LayoutUpdated", ("revision", "parent"));
        b.signal::<(Vec<(i32, PropMap)>, Vec<(i32, Vec<String>)>), _>(
            "ItemsPropertiesUpdated",
            ("updated", "removed"),
        );
        b.signal::<(i32, u32), _>("ItemActivationRequested", ("id", "timestamp"));
        b.method(
            "GetLayout",
            ("parentId", "recursionDepth", "propertyNames"),
            ("revision", "layout"),
            |_, _: &mut Item, (id, depth, names): (i32, i32, Vec<String>)| {
                Ok((1u32, layout(id, depth, &names)?))
            },
        );
        b.method(
            "GetGroupProperties",
            ("ids", "propertyNames"),
            ("properties",),
            |_, _: &mut Item, (mut ids, names): (Vec<i32>, Vec<String>)| {
                if ids.len() > 32 || names.len() > 32 {
                    return Err(MethodErr::failed("Too many menu properties"));
                }
                if ids.is_empty() {
                    ids = vec![0, 1, 2];
                }
                Ok((ids
                    .into_iter()
                    .filter_map(|id| properties(id, &names).ok().map(|p| (id, p)))
                    .collect::<Vec<_>>(),))
            },
        );
        b.method(
            "GetProperty",
            ("id", "name"),
            ("value",),
            |_, _: &mut Item, (id, name): (i32, String)| {
                Ok((properties(id, &[])?
                    .remove(&name)
                    .ok_or_else(|| MethodErr::failed("Unknown menu property"))?,))
            },
        );
        b.method(
            "Event",
            ("id", "eventId", "data", "timestamp"),
            (),
            |_, item: &mut Item, (id, name, _, _): (i32, String, Variant<Box<dyn RefArg>>, u32)| {
                event(item, id, &name)
            },
        );
        b.method(
            "EventGroup",
            ("events",),
            ("idErrors",),
            |_,
             item: &mut Item,
             (events,): (Vec<(i32, String, Variant<Box<dyn RefArg>>, u32)>,)| {
                if events.len() > 32 {
                    return Err(MethodErr::failed("Too many menu events"));
                }
                Ok((events
                    .into_iter()
                    .filter_map(|(id, name, _, _)| event(item, id, &name).err().map(|_| id))
                    .collect::<Vec<_>>(),))
            },
        );
        b.method(
            "AboutToShow",
            ("id",),
            ("needUpdate",),
            |_, _: &mut Item, (id,): (i32,)| {
                properties(id, &[])?;
                Ok((false,))
            },
        );
        b.method(
            "AboutToShowGroup",
            ("ids",),
            ("updatesNeeded", "idErrors"),
            |_, _: &mut Item, (ids,): (Vec<i32>,)| {
                if ids.len() > 32 {
                    return Err(MethodErr::failed("Too many menu items"));
                }
                Ok((
                    Vec::<i32>::new(),
                    ids.into_iter()
                        .filter(|id| !(0..=2).contains(id))
                        .collect::<Vec<_>>(),
                ))
            },
        );
    })
}
