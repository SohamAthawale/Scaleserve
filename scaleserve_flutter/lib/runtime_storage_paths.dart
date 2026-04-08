import 'dart:io';

class RuntimeStoragePaths {
  RuntimeStoragePaths._();

  static Directory baseDirectory() {
    final projectRoot = _projectRootDirectory();
    return Directory('${projectRoot.path}/scaleserve_runtime');
  }

  static File localSettingsFile() =>
      File('${baseDirectory().path}/local_settings.json');

  static File remoteStateFile() =>
      File('${baseDirectory().path}/remote_compute_state.json');

  static File machineInventoryFile() =>
      File('${baseDirectory().path}/machine_inventory.json');

  static File commandLogsFile() =>
      File('${baseDirectory().path}/command_logs.json');

  static Directory _projectRootDirectory() {
    var current = Directory.current.absolute;
    for (var i = 0; i < 10; i++) {
      final gitDirectory = Directory('${current.path}/.git');
      if (gitDirectory.existsSync()) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    return Directory.current.absolute;
  }
}
