import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

const int modbusPortDefault = 1502;
const int uiTailKeep = 2000;

void main() {
  runApp(const ModbusSimulatorApp());
}

enum RegisterAccess { read, write, readWrite }

class ModbusSimulatorApp extends StatelessWidget {
  const ModbusSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Borunte Emulator',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
      ),
      home: const ModbusDashboard(),
    );
  }
}

class RegisterRange {
  RegisterRange({
    required this.name,
    required this.start,
    required this.access,
    this.length = 1,
    this.valueType = RegisterValueType.word,
    this.valueIndex = 0,
  });

  final String name;
  final int start;
  final RegisterAccess access;
  final int length;
  final RegisterValueType valueType;
  final int valueIndex;

  String get label => '$name (0x${start.toRadixString(16).toUpperCase().padLeft(4, '0')})';

  int get storageLength => valueType == RegisterValueType.word ? length : 1;

  String get typeLabel {
    switch (valueType) {
      case RegisterValueType.bit:
        return 'bit#$valueIndex';
      case RegisterValueType.byte:
        return 'byte#$valueIndex';
      case RegisterValueType.word:
        return length > 1 ? 'word[$length]' : 'word';
    }
  }

  String get accessLabel {
    switch (access) {
      case RegisterAccess.read:
        return 'R';
      case RegisterAccess.write:
        return 'W';
      case RegisterAccess.readWrite:
        return 'RW';
    }
  }

  String displayValue(SparseHoldingRegisterBank bank) {
    final List<int>? values = bank.readRangeRaw(start, storageLength);
    if (values == null || values.isEmpty) {
      return 'ERR';
    }

    switch (valueType) {
      case RegisterValueType.word:
        return values.toString();
      case RegisterValueType.byte:
        final int rawWord = values.first;
        final int byteValue = valueIndex == 0 ? rawWord & 0xFF : (rawWord >> 8) & 0xFF;
        return '$byteValue (0x${byteValue.toRadixString(16).toUpperCase().padLeft(2, '0')})';
      case RegisterValueType.bit:
        final int rawWord = values.first;
        final int bitValue = (rawWord >> valueIndex) & 0x1;
        return '$bitValue';
    }
  }

  bool isChanged(SparseHoldingRegisterBank bank, Duration window) {
    for (int i = 0; i < storageLength; i++) {
      if (bank.isRecentlyChanged(start + i, window)) {
        return true;
      }
    }
    return false;
  }
}

enum RegisterValueType { bit, byte, word }

class WriteEvent {
  WriteEvent({
    required this.seq,
    required this.ts,
    required this.unitId,
    required this.addr,
    required this.values,
  });

  final int seq;
  final DateTime ts;
  final int unitId;
  final int addr;
  final List<int> values;

  int get count => values.length;
}

class EventSink {
  final List<WriteEvent> _tail = <WriteEvent>[];
  int _seq = 0;

  List<WriteEvent> getTail({int limit = 50}) {
    final int safeLimit = limit.clamp(1, uiTailKeep);
    final List<WriteEvent> data = _tail.reversed.take(safeLimit).toList();
    return data;
  }

  void addWrite({required int unitId, required int addr, required List<int> values}) {
    _seq += 1;
    _tail.add(WriteEvent(seq: _seq, ts: DateTime.now(), unitId: unitId, addr: addr, values: values));
    if (_tail.length > uiTailKeep) {
      _tail.removeRange(0, _tail.length - uiTailKeep);
    }
  }
}

class SparseHoldingRegisterBank {
  SparseHoldingRegisterBank(this.onWrite);

  final void Function(int unitId, int addr, List<int> values) onWrite;

  final Map<int, int> _values = <int, int>{};
  final Map<int, RegisterAccess> _accessByAddress = <int, RegisterAccess>{};
  final Map<int, DateTime> _changedAt = <int, DateTime>{};

  bool addRange(int start, int length, RegisterAccess access) {
    if (start < 0 || length <= 0) {
      return false;
    }
    for (int i = 0; i < length; i++) {
      if (_values.containsKey(start + i)) {
        return false;
      }
    }
    for (int i = 0; i < length; i++) {
      final int addr = start + i;
      _values[addr] = 0;
      _accessByAddress[addr] = access;
    }
    return true;
  }

  void removeRange(int start, int length) {
    for (int i = 0; i < length; i++) {
      final int addr = start + i;
      _values.remove(addr);
      _accessByAddress.remove(addr);
      _changedAt.remove(addr);
    }
  }

  bool _validate(int start, int count, {required bool forWrite}) {
    if (count <= 0 || start < 0) {
      return false;
    }
    for (int i = 0; i < count; i++) {
      final int addr = start + i;
      final RegisterAccess? access = _accessByAddress[addr];
      if (access == null) {
        return false;
      }
      if (forWrite && access == RegisterAccess.read) {
        return false;
      }
      if (!forWrite && access == RegisterAccess.write) {
        return false;
      }
    }
    return true;
  }

  List<int>? readRange(int start, int count) {
    if (!_validate(start, count, forWrite: false)) {
      return null;
    }
    return readRangeRaw(start, count);
  }

  List<int>? readRangeRaw(int start, int count) {
    if (count <= 0 || start < 0) {
      return null;
    }
    for (int i = 0; i < count; i++) {
      if (!_values.containsKey(start + i)) {
        return null;
      }
    }
    return List<int>.generate(count, (int i) => _values[start + i] ?? 0);
  }

  bool writeSingle(int unitId, int address, int value) {
    if (!_validate(address, 1, forWrite: true)) {
      return false;
    }
    _values[address] = value & 0xFFFF;
    _changedAt[address] = DateTime.now();
    onWrite(unitId, address, <int>[value & 0xFFFF]);
    return true;
  }

  bool writeMultiple(int unitId, int start, List<int> values) {
    if (!_validate(start, values.length, forWrite: true)) {
      return false;
    }
    for (int i = 0; i < values.length; i++) {
      _values[start + i] = values[i] & 0xFFFF;
      _changedAt[start + i] = DateTime.now();
    }
    onWrite(unitId, start, values.map((int e) => e & 0xFFFF).toList());
    return true;
  }

  bool isRecentlyChanged(int address, Duration window) {
    final DateTime? changedAt = _changedAt[address];
    if (changedAt == null) {
      return false;
    }
    return DateTime.now().difference(changedAt) <= window;
  }
}

class ModbusLogEntry {
  ModbusLogEntry({
    required this.timestamp,
    required this.client,
    required this.functionCode,
    required this.startAddress,
    required this.length,
    required this.result,
  });

  final DateTime timestamp;
  final String client;
  final int functionCode;
  final int startAddress;
  final int length;
  final String result;
}

class ModbusTcpServer {
  ModbusTcpServer({required this.bank, required this.onRegistersChanged, required this.onLog});

  final SparseHoldingRegisterBank bank;
  final VoidCallback onRegistersChanged;
  final void Function(ModbusLogEntry entry) onLog;

  ServerSocket? _server;
  final List<Socket> _clients = <Socket>[];
  final Map<Socket, BytesBuilder> _buffers = <Socket, BytesBuilder>{};

  Future<void> start({required int port, InternetAddress? address}) async {
    await stop();
    _server = await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.listen((Socket client) {
      _clients.add(client);
      _buffers[client] = BytesBuilder(copy: false);
      client.listen(
        (Uint8List data) => _handleIncomingData(client, data),
        onDone: () {
          _clients.remove(client);
          _buffers.remove(client);
        },
        onError: (_) {
          _clients.remove(client);
          _buffers.remove(client);
          client.destroy();
        },
      );
    });
  }

  Future<void> stop() async {
    for (final Socket client in List<Socket>.from(_clients)) {
      client.destroy();
    }
    _clients.clear();
    _buffers.clear();
    await _server?.close();
    _server = null;
  }

  void _handleIncomingData(Socket client, Uint8List data) {
    final BytesBuilder? buffer = _buffers[client];
    if (buffer == null) {
      return;
    }

    buffer.add(data);
    Uint8List pending = buffer.toBytes();

    while (pending.length >= 7) {
      final ByteData header = ByteData.sublistView(pending, 0, 6);
      final int protocolId = header.getUint16(2);
      final int length = header.getUint16(4);

      if (protocolId != 0 || length < 2) {
        client.destroy();
        _clients.remove(client);
        _buffers.remove(client);
        return;
      }

      final int frameLen = 6 + length;
      if (pending.length < frameLen) {
        break;
      }

      final Uint8List frame = Uint8List.sublistView(pending, 0, frameLen);
      _handleRequestFrame(client, frame);
      pending = Uint8List.sublistView(pending, frameLen);
    }

    final BytesBuilder next = BytesBuilder(copy: false);
    if (pending.isNotEmpty) {
      next.add(pending);
    }
    _buffers[client] = next;
  }

  void _handleRequestFrame(Socket client, Uint8List data) {
    if (data.length < 8) {
      return;
    }

    final ByteData view = ByteData.sublistView(data);
    final int transactionId = view.getUint16(0);
    final int length = view.getUint16(4);
    if (data.length != 6 + length) {
      return;
    }

    final int unitId = data[6];
    final Uint8List pdu = Uint8List.sublistView(data, 7, 6 + length);
    if (pdu.isEmpty) {
      return;
    }

    final int functionCode = pdu[0];
    final String clientId = '${client.remoteAddress.address}:${client.remotePort}';

    switch (functionCode) {
      case 3:
        _handleReadHoldingRegisters(client, transactionId, unitId, pdu, clientId);
        break;
      case 6:
        _handleWriteSingleRegister(client, transactionId, unitId, pdu, clientId);
        break;
      case 16:
        _handleWriteMultipleRegisters(client, transactionId, unitId, pdu, clientId);
        break;
      default:
        _sendException(client, transactionId, unitId, functionCode, 0x01);
        _log(clientId, functionCode, 0, 0, 'exception');
    }
  }

  void _handleReadHoldingRegisters(Socket client, int tid, int unitId, Uint8List pdu, String clientId) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int start = body.getUint16(1);
    final int count = body.getUint16(3);

    final List<int>? values = bank.readRange(start, count);
    if (values == null) {
      _sendException(client, tid, unitId, 3, 0x02);
      _log(clientId, 3, start, count, 'exception');
      return;
    }

    final BytesBuilder responsePdu = BytesBuilder();
    responsePdu..addByte(3)..addByte(count * 2);
    for (final int value in values) {
      responsePdu.add(<int>[(value >> 8) & 0xFF, value & 0xFF]);
    }

    _sendResponse(client, tid, unitId, responsePdu.toBytes());
    _log(clientId, 3, start, count, 'ok');
  }

  void _handleWriteSingleRegister(Socket client, int tid, int unitId, Uint8List pdu, String clientId) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int address = body.getUint16(1);
    final int value = body.getUint16(3);

    if (!bank.writeSingle(unitId, address, value)) {
      _sendException(client, tid, unitId, 6, 0x02);
      _log(clientId, 6, address, 1, 'exception');
      return;
    }

    _sendResponse(client, tid, unitId, pdu);
    _log(clientId, 6, address, 1, 'ok');
    onRegistersChanged();
  }

  void _handleWriteMultipleRegisters(Socket client, int tid, int unitId, Uint8List pdu, String clientId) {
    if (pdu.length < 6) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int start = body.getUint16(1);
    final int count = body.getUint16(3);
    final int byteCount = pdu[5];

    if (pdu.length != 6 + byteCount || byteCount != count * 2) {
      return;
    }

    final List<int> values = <int>[];
    for (int i = 0; i < count; i++) {
      final int offset = 6 + i * 2;
      values.add((pdu[offset] << 8) | pdu[offset + 1]);
    }

    if (!bank.writeMultiple(unitId, start, values)) {
      _sendException(client, tid, unitId, 16, 0x02);
      _log(clientId, 16, start, count, 'exception');
      return;
    }

    _sendResponse(
      client,
      tid,
      unitId,
      Uint8List.fromList(<int>[16, (start >> 8) & 0xFF, start & 0xFF, (count >> 8) & 0xFF, count & 0xFF]),
    );
    _log(clientId, 16, start, count, 'ok');
    onRegistersChanged();
  }

  void _sendException(Socket client, int tid, int unitId, int function, int exceptionCode) {
    _sendResponse(client, tid, unitId, Uint8List.fromList(<int>[function | 0x80, exceptionCode]));
  }

  void _sendResponse(Socket client, int tid, int unitId, Uint8List pdu) {
    final int length = pdu.length + 1;
    final BytesBuilder frame = BytesBuilder();
    frame
      ..add(<int>[(tid >> 8) & 0xFF, tid & 0xFF])
      ..add(<int>[0, 0])
      ..add(<int>[(length >> 8) & 0xFF, length & 0xFF])
      ..addByte(unitId)
      ..add(pdu);
    client.add(frame.toBytes());
  }

  void _log(String clientId, int fc, int start, int len, String result) {
    onLog(
      ModbusLogEntry(
        timestamp: DateTime.now(),
        client: clientId,
        functionCode: fc,
        startAddress: start,
        length: len,
        result: result,
      ),
    );
  }
}

class ModbusDashboard extends StatefulWidget {
  const ModbusDashboard({super.key});

  @override
  State<ModbusDashboard> createState() => _ModbusDashboardState();
}

class _ModbusDashboardState extends State<ModbusDashboard> {
  static const Duration highlightWindow = Duration(seconds: 5);

  late final SparseHoldingRegisterBank _bank;
  late final ModbusTcpServer _server;
  late final Timer _uiTimer;
  final EventSink _sink = EventSink();

  final List<RegisterRange> _ranges = <RegisterRange>[];
  final Map<int, TextEditingController> _rangeValueControllers = <int, TextEditingController>{};

  final TextEditingController _portController = TextEditingController(text: '$modbusPortDefault');
  final TextEditingController _addNameController = TextEditingController();
  final TextEditingController _addStartController = TextEditingController();
  final TextEditingController _addLenController = TextEditingController(text: '1');
  final TextEditingController _addIndexController = TextEditingController(text: '0');
  final TextEditingController _yamlExportPathController = TextEditingController(text: 'examples/registers_config.yaml');
  RegisterValueType _addType = RegisterValueType.word;
  RegisterAccess _addAccess = RegisterAccess.readWrite;

  final List<ModbusLogEntry> _requestLog = <ModbusLogEntry>[];

  int _port = modbusPortDefault;
  String _status = 'Stopped';

  @override
  void initState() {
    super.initState();
    _bank = SparseHoldingRegisterBank((int unitId, int addr, List<int> values) {
      _sink.addWrite(unitId: unitId, addr: addr, values: values);
    });

    _server = ModbusTcpServer(bank: _bank, onRegistersChanged: _refresh, onLog: _addReqLog);

    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    _startServer();
  }

  @override
  void dispose() {
    _uiTimer.cancel();
    _server.stop();
    _portController.dispose();
    _addNameController.dispose();
    _addStartController.dispose();
    _addLenController.dispose();
    _addIndexController.dispose();
    _yamlExportPathController.dispose();
    for (final TextEditingController controller in _rangeValueControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addReqLog(ModbusLogEntry entry) {
    if (!mounted) {
      return;
    }
    setState(() {
      _requestLog.insert(0, entry);
      if (_requestLog.length > 200) {
        _requestLog.removeLast();
      }
    });
  }

  void _refresh() {
    _syncRangeValueControllers();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncRangeValueControllers() {
    for (final RegisterRange range in _ranges) {
      final TextEditingController? controller = _rangeValueControllers[range.start];
      if (controller == null) {
        continue;
      }
      final List<int>? values = _bank.readRangeRaw(range.start, range.storageLength);
      if (values == null) {
        continue;
      }
      final String text = values.length == 1 ? values.first.toString() : jsonEncode(values);
      if (controller.text != text) {
        controller.text = text;
      }
    }
  }

  Future<void> _startServer() async {
    try {
      await _server.start(port: _port);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Running on 0.0.0.0:$_port';
      });
    } on SocketException catch (e) {
      setState(() {
        _status = 'Start error: ${e.message}';
      });
    }
  }

  Future<void> _restartServer() async {
    final int? parsedPort = int.tryParse(_portController.text);
    if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
      return;
    }
    _port = parsedPort;
    await _startServer();
  }

  Future<void> _stopServer() async {
    await _server.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Stopped';
    });
  }

  void _writeRangeValue(RegisterRange range) {
    if (range.access == RegisterAccess.read) {
      return;
    }

    final TextEditingController? controller = _rangeValueControllers[range.start];
    if (controller == null) {
      return;
    }

    final String text = controller.text.trim();
    List<int> values;
    if (text.startsWith('[')) {
      final dynamic decoded = jsonDecode(text);
      if (decoded is! List) {
        return;
      }
      values = decoded.map((dynamic e) => (e as num).toInt()).toList();
    } else {
      final int? parsed = int.tryParse(text);
      if (parsed == null) {
        return;
      }
      values = <int>[parsed];
    }

    final bool ok = _bank.writeMultiple(0, range.start, values);
    if (ok) {
      _refresh();
    }
  }

  void _addRange() {
    final String name = _addNameController.text.trim();
    final int? start = int.tryParse(_addStartController.text.trim());
    final int? len = int.tryParse(_addLenController.text.trim());
    final int? index = int.tryParse(_addIndexController.text.trim());

    if (name.isEmpty || start == null || len == null || start < 0 || len < 1 || index == null || index < 0) {
      return;
    }

    if (_addType == RegisterValueType.bit && index > 15) {
      return;
    }

    if (_addType == RegisterValueType.byte && index > 1) {
      return;
    }

    final int safeLength = _addType == RegisterValueType.word ? len : 1;
    final RegisterRange range = RegisterRange(
      name: name,
      start: start,
      access: _addAccess,
      length: safeLength,
      valueType: _addType,
      valueIndex: index,
    );
    final bool added = _bank.addRange(start, range.storageLength, _addAccess);
    if (!added) {
      return;
    }

    setState(() {
      _ranges.add(range);
      _rangeValueControllers[start] = TextEditingController(
        text: safeLength > 1 ? jsonEncode(List<int>.filled(safeLength, 0)) : '0',
      );
      _addNameController.clear();
      _addStartController.clear();
      _addLenController.text = '1';
      _addIndexController.text = '0';
    });
  }

  void _removeRange(int index) {
    if (index < 0 || index >= _ranges.length) {
      return;
    }
    setState(() {
      final RegisterRange range = _ranges.removeAt(index);
      _bank.removeRange(range.start, range.storageLength);
      _rangeValueControllers.remove(range.start)?.dispose();
    });
  }

  String _registerAccessToYaml(RegisterAccess access) {
    switch (access) {
      case RegisterAccess.read:
        return 'read';
      case RegisterAccess.write:
        return 'write';
      case RegisterAccess.readWrite:
        return 'read_write';
    }
  }

  String _registerTypeToYaml(RegisterValueType type) {
    switch (type) {
      case RegisterValueType.bit:
        return 'bit';
      case RegisterValueType.byte:
        return 'byte';
      case RegisterValueType.word:
        return 'word';
    }
  }

  String _escapeYamlString(String value) {
    return value.replaceAll("'", "''");
  }

  Future<void> _exportConfigToYaml() async {
    final String rawPath = _yamlExportPathController.text.trim();
    if (rawPath.isEmpty) {
      setState(() {
        _status = 'Export error: empty YAML file path';
      });
      return;
    }

    final StringBuffer yaml = StringBuffer()
      ..writeln('version: 1')
      ..writeln('inputs:');

    for (final RegisterRange range in _ranges) {
      final List<int>? values = _bank.readRangeRaw(range.start, range.storageLength);
      yaml
        ..writeln("  - name: '${_escapeYamlString(range.name)}'")
        ..writeln('    address: ${range.start}')
        ..writeln('    access: ${_registerAccessToYaml(range.access)}')
        ..writeln('    value_type: ${_registerTypeToYaml(range.valueType)}')
        ..writeln('    length: ${range.length}');
      if (range.valueType != RegisterValueType.word || range.valueIndex != 0) {
        yaml.writeln('    index: ${range.valueIndex}');
      }
      if (values != null && values.any((int value) => value != 0)) {
        yaml.writeln('    values: [${values.join(', ')}]');
      }
      yaml.writeln();
    }

    try {
      final File output = File(rawPath);
      await output.parent.create(recursive: true);
      await output.writeAsString(yaml.toString());
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Exported ${_ranges.length} inputs to ${output.path}';
      });
    } on FileSystemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Export error: ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<WriteEvent> writes = _sink.getTail(limit: 50);

    return Scaffold(
      appBar: AppBar(title: const Text('Borunte Robot Emulator (Strict Mode v3)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                FilledButton(onPressed: _restartServer, child: const Text('Start/Restart')),
                OutlinedButton(onPressed: _stopServer, child: const Text('Stop')),
                Text(_status),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Column(
                children: [
                  Expanded(flex: 3, child: _buildRangesPanel()),
                  const SizedBox(height: 12),
                  Expanded(flex: 2, child: _buildWritesPanel(writes)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(height: 130, child: _buildRequestPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildWritesPanel(List<WriteEvent> writes) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Write Logs (From PLC/UI)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: writes.length,
                itemBuilder: (BuildContext context, int index) {
                  final WriteEvent w = writes[index];
                  final String t =
                      '${w.ts.hour.toString().padLeft(2, '0')}:${w.ts.minute.toString().padLeft(2, '0')}:${w.ts.second.toString().padLeft(2, '0')}';
                  return Text(
                    '#${w.seq} $t u=${w.unitId} 0x${w.addr.toRadixString(16).toUpperCase()} (${w.addr}) ${w.values}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangesPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Registers', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _ranges.length,
                itemBuilder: (BuildContext context, int index) {
                  final RegisterRange range = _ranges[index];
                  final bool changed = range.isChanged(_bank, highlightWindow);
                  final TextEditingController? valueController = _rangeValueControllers[range.start];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      color: changed ? Colors.yellow.withValues(alpha: 0.18) : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${range.name} | ${range.start} | ${range.typeLabel} | ${range.accessLabel}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _removeRange(index),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
                        ),
                        Text('Current: ${range.displayValue(_bank)}', style: const TextStyle(fontSize: 12)),
                        if (valueController != null) ...<Widget>[
                          const SizedBox(height: 4),
                          TextField(
                            controller: valueController,
                            enabled: range.access != RegisterAccess.read,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'New value (number or [..])',
                            ),
                          ),
                          const SizedBox(height: 4),
                          FilledButton(
                            onPressed: range.access == RegisterAccess.read ? null : () => _writeRangeValue(range),
                            child: const Text('Write value'),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            const Divider(),
            TextField(controller: _addNameController, decoration: const InputDecoration(labelText: 'Name')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addStartController,
                    decoration: const InputDecoration(labelText: 'Address'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<RegisterAccess>(
                    value: _addAccess,
                    decoration: const InputDecoration(labelText: 'Access'),
                    items: const <DropdownMenuItem<RegisterAccess>>[
                      DropdownMenuItem<RegisterAccess>(value: RegisterAccess.read, child: Text('R (Read)')),
                      DropdownMenuItem<RegisterAccess>(value: RegisterAccess.write, child: Text('W (Write)')),
                      DropdownMenuItem<RegisterAccess>(value: RegisterAccess.readWrite, child: Text('RW (Read/Write)')),
                    ],
                    onChanged: (RegisterAccess? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _addAccess = value;
                      });
                    },
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<RegisterValueType>(
                    value: _addType,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: RegisterValueType.values
                        .map(
                          (RegisterValueType type) => DropdownMenuItem<RegisterValueType>(
                            value: type,
                            child: Text(type.name),
                          ),
                        )
                        .toList(),
                    onChanged: (RegisterValueType? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _addType = value;
                        if (_addType != RegisterValueType.word) {
                          _addLenController.text = '1';
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _addLenController,
                    decoration: InputDecoration(
                      labelText: _addType == RegisterValueType.word ? 'Words count' : 'Words count (fixed 1)',
                    ),
                    keyboardType: TextInputType.number,
                    enabled: _addType == RegisterValueType.word,
                  ),
                ),
              ],
            ),
            TextField(
              controller: _addIndexController,
              decoration: InputDecoration(
                labelText: _addType == RegisterValueType.bit
                    ? 'Bit index (0..15)'
                    : _addType == RegisterValueType.byte
                        ? 'Byte index (0..1)'
                        : 'Index (0)',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 6),
            FilledButton(onPressed: _addRange, child: const Text('Add address/range')),
            const SizedBox(height: 10),
            TextField(
              controller: _yamlExportPathController,
              decoration: const InputDecoration(
                labelText: 'YAML export path',
                helperText: 'Example format: examples/registers_config.example.yaml',
              ),
            ),
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: _exportConfigToYaml,
              icon: const Icon(Icons.download),
              label: const Text('Экспортировать YAML конфигурацию'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestPanel() {
    return Card(
      child: ListView.builder(
        itemCount: _requestLog.length,
        itemBuilder: (BuildContext context, int index) {
          final ModbusLogEntry e = _requestLog[index];
          final String t =
              '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}:${e.timestamp.second.toString().padLeft(2, '0')}';
          return ListTile(
            dense: true,
            title: Text('$t ${e.client} FC${e.functionCode} ${e.result}'),
            subtitle: Text('addr=${e.startAddress} len=${e.length}'),
          );
        },
      ),
    );
  }
}
