# ADR-0006: XcodeGen project.yml instead of a committed .xcodeproj

**Status:** accepted

This workspace was authored in a Linux environment with no Xcode; a hand-written pbxproj
is unverifiable and merge-hostile. `project.yml` declares the app + Live Activity targets,
Info.plist properties (permission strings, background modes, BGTask identifiers), and
entitlements; `xcodegen generate` on a Mac produces the project deterministically. CI's
macOS job does exactly this.
