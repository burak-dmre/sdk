// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io' show File, FileSystemException, InternetAddress, Socket;

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'commands/compilation_server.dart' show CompilationServerCommand;
import 'resident_frontend_constants.dart';
import 'unified_analytics.dart';
import 'utils.dart' show maybeUriToFilename;

/// The Resident Frontend Compiler's shutdown command.
final residentServerShutdownCommand = jsonEncode(
  <String, Object>{
    commandString: shutdownString,
  },
);

/// The default resident frontend compiler information file.
///
/// Resident frontend compiler info files contain the contents:
/// `address:$address port:$port`.
File? get defaultResidentServerInfoFile {
  var dartConfigDir = getDartStorageDirectory();
  if (dartConfigDir == null) return null;

  return File(p.join(dartConfigDir.path, 'dartdev_compilation_server_info'));
}

File? getResidentCompilerInfoFileConsideringArgs(final ArgResults args) {
  if (args.wasParsed(CompilationServerCommand.residentCompilerInfoFileFlag)) {
    return File(maybeUriToFilename(
      args[CompilationServerCommand.residentCompilerInfoFileFlag],
    ));
  } else if (args.wasParsed(
    CompilationServerCommand.legacyResidentServerInfoFileFlag,
  )) {
    return File(maybeUriToFilename(
      args[CompilationServerCommand.legacyResidentServerInfoFileFlag],
    ));
  } else if (defaultResidentServerInfoFile != null) {
    return defaultResidentServerInfoFile!;
  } else {
    return null;
  }
}

final String packageConfigName = p.join('.dart_tool', 'package_config.json');

/// Get the port number the Resident Frontend Compiler is listening on.
int getPortNumber(String serverInfo) =>
    int.parse(serverInfo.substring(serverInfo.lastIndexOf(':') + 1));

/// Get the address that the Resident Frontend Compiler is listening from.
InternetAddress getAddress(String serverInfo) => InternetAddress(
    serverInfo.substring(serverInfo.indexOf(':') + 1, serverInfo.indexOf(' ')));

/// Removes the [serverInfoFile].
void cleanupResidentServerInfo(File serverInfoFile) {
  if (serverInfoFile.existsSync()) {
    try {
      serverInfoFile.deleteSync();
    } catch (_) {}
  }
}

Future<bool> isFileKernelFile(final File file) async {
  final bytes = await file.openRead(0, 4).expand((i) => i).toList();
  if (bytes.length < 4) {
    return false;
  }
  // Check for the magic number at the start of kernel files.
  return bytes[0] == 0x90 &&
      bytes[1] == 0xab &&
      bytes[2] == 0xcd &&
      bytes[3] == 0xef;
}

Future<bool> isFileAppJitSnapshot(final File file) async {
  final bytes = await file.openRead(0, 8).expand((i) => i).toList();
  if (bytes.length < 8) {
    return false;
  }
  // Check for the magic number at the start of AppJIT snapshots.
  return bytes[0] == 0xdc &&
      bytes[1] == 0xdc &&
      bytes[2] == 0xf6 &&
      bytes[3] == 0xf6 &&
      bytes[4] == 0 &&
      bytes[5] == 0 &&
      bytes[6] == 0 &&
      bytes[7] == 0;
}

Future<bool> isFileAotSnapshot(final File file) async {
  // Check for any of the the magic numbers that can be found at the start of an
  // AOT snapshot.

  final bytes = await file.openRead(0, 4).expand((i) => i).toList();
  // Check for the COFF magic numbers.
  if (bytes.length < 2) {
    return false;
  }
  if (bytes[0] == 0x01 && bytes[1] == 0xc0 || // arm32
      bytes[0] == 0xaa && bytes[1] == 0x64 || // arm64
      bytes[0] == 0x50 && bytes[1] == 0x32 || // riscv32
      bytes[0] == 0x50 && bytes[1] == 0x64 /* riscv64 */) {
    return true;
  }

  if (bytes.length < 4) {
    return false;
  }
  // Check for the ELF magic number.
  if (bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46) {
    return true;
  }
  // Check for the Mach-O magic numbers.
  if (bytes[0] == 0xfe &&
      bytes[1] == 0xed &&
      bytes[2] == 0xfa &&
      bytes[3] == 0xce) {
    // macho32
    return true;
  }
  if (bytes[0] == 0xfe &&
      bytes[1] == 0xed &&
      bytes[2] == 0xfa &&
      bytes[3] == 0xcf) {
    // macho64
    return true;
  }
  if (bytes[0] == 0xcf &&
      bytes[1] == 0xfa &&
      bytes[2] == 0xed &&
      bytes[3] == 0xfe) {
    // macho64_arm64
    return true;
  }

  return false;
}

// TODO: when frontend_server is migrated to null safe Dart, everything
// below this comment can be removed and imported from resident_frontend_server

/// Sends a compilation [request] to the Resident Frontend Compiler, returning
/// it's json response.
///
/// Throws a [FileSystemException] if there is no server running.
Future<Map<String, dynamic>> sendAndReceiveResponse(
  String request,
  File serverInfoFile,
) async {
  Socket? client;
  Map<String, dynamic> jsonResponse;
  final contents = serverInfoFile.readAsStringSync();
  try {
    client =
        await Socket.connect(getAddress(contents), getPortNumber(contents));
    client.write(request);
    final data = String.fromCharCodes(await client.first);
    jsonResponse = jsonDecode(data);
  } catch (e) {
    jsonResponse = <String, dynamic>{
      responseSuccessString: false,
      responseErrorString: e.toString(),
    };
  }
  client?.destroy();
  return jsonResponse;
}

/// Used to create compile requests for the run CLI command.
///
/// Returns a JSON string that the resident compiler will be able to interpret.
String createCompileJitJson({
  required String executable,
  required String outputDill,
  required ArgResults args,
  String? packages,
  bool verbose = false,
}) {
  return jsonEncode(
    <String, Object?>{
      commandString: compileString,
      sourceString: executable,
      outputString: outputDill,
      if (args.wasParsed(defineOption))
        defineOption: args.multiOption(defineOption),
      if (args.options.contains(enableAssertsOption) &&
          args.wasParsed(enableAssertsOption))
        enableAssertsOption: true,
      if (args.wasParsed(enableExperimentOption))
        enableExperimentOption: args
            .multiOption(enableExperimentOption)
            .map((e) => '--enable-experiment=$e')
            .toList(),
      if (packages != null) packageString: packages,
      if (args.wasParsed(verbosityOption))
        verbosityOption: args.flag(verbosityOption),
    },
  );
}
