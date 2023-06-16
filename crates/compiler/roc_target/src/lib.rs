//! Provides types and helpers for compiler targets such as `default_x86_64`.
#![warn(clippy::dbg_macro)]
// See github.com/roc-lang/roc/issues/800 for discussion of the large_enum_variant check.
#![allow(clippy::large_enum_variant)]

use strum_macros::{EnumCount, EnumIter};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum OperatingSystem {
    Windows,
    Unix,
    Wasi,
}

impl OperatingSystem {
    pub const fn new(target: target_lexicon::OperatingSystem) -> Option<Self> {
        match target {
            target_lexicon::OperatingSystem::Windows => Some(OperatingSystem::Windows),
            target_lexicon::OperatingSystem::Wasi => Some(OperatingSystem::Wasi),
            target_lexicon::OperatingSystem::Linux => Some(OperatingSystem::Unix),
            target_lexicon::OperatingSystem::MacOSX { .. } => Some(OperatingSystem::Unix),
            target_lexicon::OperatingSystem::Darwin => Some(OperatingSystem::Unix),
            target_lexicon::OperatingSystem::Unknown => Some(OperatingSystem::Unix),
            _ => None,
        }
    }

    pub const fn object_file_ext(&self) -> &str {
        match self {
            OperatingSystem::Windows => "obj",
            OperatingSystem::Unix => "o",
            OperatingSystem::Wasi => "wasm",
        }
    }

    pub const fn executable_file_ext(&self) -> Option<&str> {
        match self {
            OperatingSystem::Windows => Some("exe"),
            OperatingSystem::Unix => None,
            OperatingSystem::Wasi => Some("wasm"),
        }
    }
}

impl From<target_lexicon::OperatingSystem> for OperatingSystem {
    fn from(target: target_lexicon::OperatingSystem) -> Self {
        Self::new(target)
            .unwrap_or_else(|| unreachable!("unsupported operating system {:?}", target))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TargetInfo {
    pub architecture: Architecture,
    pub operating_system: OperatingSystem,
}

impl TargetInfo {
    pub const fn ptr_width(&self) -> PtrWidth {
        self.architecture.ptr_width()
    }

    pub const fn ptr_size(&self) -> usize {
        match self.ptr_width() {
            PtrWidth::Bytes4 => 4,
            PtrWidth::Bytes8 => 8,
        }
    }

    pub const fn max_by_value_size(&self) -> usize {
        // Pass values larger than 1M machine words by reference.
        self.ptr_size() * 1_000_000
    }

    pub const fn ptr_alignment_bytes(&self) -> usize {
        self.architecture.ptr_alignment_bytes()
    }

    pub const fn default_aarch64() -> Self {
        TargetInfo {
            architecture: Architecture::Aarch64,
            operating_system: OperatingSystem::Unix,
        }
    }

    pub const fn default_x86_64() -> Self {
        TargetInfo {
            architecture: Architecture::X86_64,
            operating_system: OperatingSystem::Unix,
        }
    }

    pub const fn default_wasm32() -> Self {
        TargetInfo {
            architecture: Architecture::Wasm32,
            operating_system: OperatingSystem::Wasi,
        }
    }
}

impl From<&target_lexicon::Triple> for TargetInfo {
    fn from(triple: &target_lexicon::Triple) -> Self {
        let architecture = Architecture::from(triple.architecture);
        let operating_system = OperatingSystem::from(triple.operating_system);

        Self {
            architecture,
            operating_system,
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtrWidth {
    Bytes4 = 4,
    Bytes8 = 8,
}

/// These should be sorted alphabetically!
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, EnumIter, EnumCount)]
#[repr(u8)]
pub enum Architecture {
    Aarch32,
    Aarch64,
    Wasm32,
    X86_32,
    X86_64,
}

impl Architecture {
    pub const fn ptr_width(&self) -> PtrWidth {
        use Architecture::*;

        match self {
            X86_64 | Aarch64 => PtrWidth::Bytes8,
            X86_32 | Aarch32 | Wasm32 => PtrWidth::Bytes4,
        }
    }

    pub const fn ptr_alignment_bytes(&self) -> usize {
        self.ptr_width() as usize
    }
}

impl From<target_lexicon::Architecture> for Architecture {
    fn from(target: target_lexicon::Architecture) -> Self {
        match target {
            target_lexicon::Architecture::X86_64 => Architecture::X86_64,
            target_lexicon::Architecture::X86_32(_) => Architecture::X86_32,
            target_lexicon::Architecture::Aarch64(_) => Architecture::Aarch64,
            target_lexicon::Architecture::Arm(_) => Architecture::Aarch32,
            target_lexicon::Architecture::Wasm32 => Architecture::Wasm32,
            _ => unreachable!("unsupported architecture"),
        }
    }
}

pub const WASM_TARGET_STR: &str = "wasm32";
pub const LINUX_X86_64_TARGET_STR: &str = "linux-x86_64";
pub const LINUX_ARM64_TARGET_STR: &str = "linux-arm64";
pub const MACOS_ARM64_TARGET_STR: &str = "macos-arm64";
pub const MACOS_X86_64_TARGET_STR: &str = "macos-x86_64";
pub const WINDOWS_X86_64_TARGET_STR: &str = "windows-x86_64";
pub const WINDOWS_X86_32_TARGET_STR: &str = "windows-x86_32";
pub const WIDNOWS_ARM64_TARGET_STR: &str = "windows-arm64";

pub fn get_target_triple_str(target: &target_lexicon::Triple) -> Option<&'static str> {
    match target {
        target_lexicon::Triple {
            architecture: target_lexicon::Architecture::Wasm32,
            ..
        } => Some(WASM_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Linux,
            architecture: target_lexicon::Architecture::X86_64,
            ..
        } => Some(LINUX_X86_64_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Linux,
            architecture: target_lexicon::Architecture::Aarch64(_),
            ..
        } => Some(LINUX_ARM64_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Darwin,
            architecture: target_lexicon::Architecture::Aarch64(_),
            ..
        } => Some(MACOS_ARM64_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Darwin,
            architecture: target_lexicon::Architecture::X86_64,
            ..
        } => Some(MACOS_X86_64_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Windows,
            architecture: target_lexicon::Architecture::X86_64,
            ..
        } => Some(WINDOWS_X86_64_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Windows,
            architecture: target_lexicon::Architecture::X86_32(_),
            ..
        } => Some(WINDOWS_X86_32_TARGET_STR),
        target_lexicon::Triple {
            operating_system: target_lexicon::OperatingSystem::Windows,
            architecture: target_lexicon::Architecture::Aarch64(_),
            ..
        } => Some(WIDNOWS_ARM64_TARGET_STR),
        _ => None,
    }
}
