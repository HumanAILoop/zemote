/// Current app version. Keep in sync with `pubspec.yaml` (version: X.Y.Z+N).
///
/// Used for update checks against the GitHub latest release. Hardcoded
/// instead of `package_info_plus` because adding a native plugin currently
/// requires Windows Developer Mode (symlink support).
const appVersion = '0.4.0';
const appBuildNumber = 1;
