//! Separate executable: the GUI never loads the media/network crate.
fn main() {
    if let Err(error) = librustdesk::farpane_native::run() {
        eprintln!("FarPane core: {error}");
        std::process::exit(1);
    }
}
