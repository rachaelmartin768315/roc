#[doc(hidden)]
pub use pretty_assertions::assert_eq as _pretty_assert_eq;

#[derive(PartialEq)]
pub struct DebugAsDisplay<T>(pub T);

impl<T: std::fmt::Display> std::fmt::Debug for DebugAsDisplay<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

#[macro_export]
macro_rules! assert_multiline_str_eq {
    ($a:expr, $b:expr) => {
        $crate::_pretty_assert_eq!($crate::DebugAsDisplay($a), $crate::DebugAsDisplay($b))
    };
}

/**
 * Creates a temporary empty directory that gets deleted when this goes out of scope.
 */
pub struct TmpDir {
    path: std::path::PathBuf,
}

impl TmpDir {
    pub fn new(dir: &str) -> TmpDir {
        let path = std::path::Path::new(dir);
        // ensure_empty_dir will fail if the dir doesn't already exist
        std::fs::create_dir_all(path).unwrap();
        remove_dir_all::ensure_empty_dir(&path).unwrap();

        let mut pathbuf = std::path::PathBuf::new();
        pathbuf.push(path);
        TmpDir { path: pathbuf }
    }

    pub fn path(&self) -> &std::path::Path {
        self.path.as_path()
    }
}

impl Drop for TmpDir {
    fn drop(&mut self) {
        remove_dir_all::remove_dir_all(&self.path).unwrap();
    }
}
