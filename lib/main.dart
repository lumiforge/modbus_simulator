import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

const int modbusPortDefault = 1502;
const int uiTailKeep = 2000;

const int addrIoIn = 0x088B;
const int lenIoIn = 10;

const int addrIoOut = 0x08B3;
const int lenIoOut = 10;

const int addrMode = 0x0889;
const int lenMode = 1;

const int addrWorld = 0x091C;
const int lenWorld = 16;

const int addrAlarm = 0x095C;
const int lenAlarm = 1;

const int addrMoveStatus = 0x09A6;
const int lenMoveStatus = 1;

const int addrParam = 0x558C;
const int lenParam = 12;

void main() {
  runApp(const ModbusSimulatorApp());
}

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
  RegisterRange({required this.name, required this.start, required this.length});

  final String name;
  final int start;
  final int length;

  String get label => '$name (0x${start.toRadixString(16).toUpperCase().padLeft(4, '0')})';
}

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
  final Map<int, int> _refCounter = <int, int>{};
  final Map<int, DateTime> _changedAt = <int, DateTime>{};

  void addRange(int start, int length) {
    for (int i = 0; i < length; i++) {
      final int addr = start + i;
      _values.putIfAbsent(addr, () => 0);
      _refCounter[addr] = (_refCounter[addr] ?? 0) + 1;
    }
  }

  void removeRange(int start, int length) {
    for (int i = 0; i < length; i++) {
      final int addr = start + i;
      final int current = _refCounter[addr] ?? 0;
      if (current <= 1) {
        _refCounter.remove(addr);
        _values.remove(addr);
        _changedAt.remove(addr);
      } else {
        _refCounter[addr] = current - 1;
      }
    }
  }

  bool validate(int start, int count) {
    if (count <= 0 || start < 0) {
      return false;
    }
    for (int i = 0; i < count; i++) {
      if (!_values.containsKey(start + i)) {
        return false;
      }
    }
    return true;
  }

  List<int>? readRange(int start, int count) {
    if (!validate(start, count)) {
      return null;
    }
    return List<int>.generate(count, (int i) => _values[start + i] ?? 0);
  }

  bool writeSingle(int unitId, int address, int value) {
    if (!validate(address, 1)) {
      return false;
    }
    _values[address] = value & 0xFFFF;
    _changedAt[address] = DateTime.now();
    onWrite(unitId, address, <int>[value & 0xFFFF]);
    return true;
  }

  bool writeMultiple(int unitId, int start, List<int> values) {
    if (!validate(start, values.length)) {
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

  int valueAt(int address) => _values[address] ?? 0;
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

  Future<void> start({required int port, InternetAddress? address}) async {
    await stop();
    _server = await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.listen((Socket client) {
      _clients.add(client);
      client.listen(
        (Uint8List data) => _handleRequest(client, data),
        onDone: () => _clients.remove(client),
        onError: (_) {
          _clients.remove(client);
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
    await _server?.close();
    _server = null;
  }

  void _handleRequest(Socket client, Uint8List data) {
    if (data.length < 8) {
      return;
    }

    final ByteData view = ByteData.sublistView(data);
    final int transactionId = view.getUint16(0);
    final int protocolId = view.getUint16(2);
    final int length = view.getUint16(4);
    if (protocolId != 0 || data.length < 6 + length) {
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

  final List<RegisterRange> _ranges = <RegisterRange>[
    RegisterRange(name: 'Robot Mode', start: addrMode, length: lenMode),
    RegisterRange(name: 'Move Status', start: addrMoveStatus, length: lenMoveStatus),
    RegisterRange(name: 'IO Inputs', start: addrIoIn, length: lenIoIn),
    RegisterRange(name: 'IO Outputs', start: addrIoOut, length: lenIoOut),
    RegisterRange(name: 'World Pos', start: addrWorld, length: lenWorld),
    RegisterRange(name: 'Alarm Num', start: addrAlarm, length: lenAlarm),
    RegisterRange(name: 'Int Params', start: addrParam, length: lenParam),
  ];

  final TextEditingController _portController = TextEditingController(text: '$modbusPortDefault');
  final TextEditingController _addNameController = TextEditingController();
  final TextEditingController _addStartController = TextEditingController();
  final TextEditingController _addLenController = TextEditingController(text: '1');

  final TextEditingController _modeController = TextEditingController(text: '0');
  final TextEditingController _moveController = TextEditingController(text: '0');
  final TextEditingController _alarmController = TextEditingController(text: '0');
  final TextEditingController _ioInController = TextEditingController(text: '[0,0,0,0,0,0,0,0,0,0]');
  final TextEditingController _worldController = TextEditingController(
    text: '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]',
  );

  final List<ModbusLogEntry> _requestLog = <ModbusLogEntry>[];

  int _port = modbusPortDefault;
  String _status = 'Stopped';

  @override
  void initState() {
    super.initState();
    _bank = SparseHoldingRegisterBank((int unitId, int addr, List<int> values) {
      _sink.addWrite(unitId: unitId, addr: addr, values: values);
    });

    for (final RegisterRange range in _ranges) {
      _bank.addRange(range.start, range.length);
    }

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
    _modeController.dispose();
    _moveController.dispose();
    _alarmController.dispose();
    _ioInController.dispose();
    _worldController.dispose();
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
    if (mounted) {
      setState(() {});
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

  Future<void> _writeByControl(int addr, TextEditingController controller) async {
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

    final bool ok = _bank.writeMultiple(0, addr, values);
    if (ok) {
      _refresh();
    }
  }

  void _addRange() {
    final String name = _addNameController.text.trim();
    final int? start = int.tryParse(_addStartController.text.trim());
    final int? len = int.tryParse(_addLenController.text.trim());
    if (name.isEmpty || start == null || len == null || start < 0 || len < 1) {
      return;
    }

    setState(() {
      final RegisterRange range = RegisterRange(name: name, start: start, length: len);
      _ranges.add(range);
      _bank.addRange(start, len);
      _addNameController.clear();
      _addStartController.clear();
      _addLenController.text = '1';
    });
  }

  void _removeRange(int index) {
    if (index < 0 || index >= _ranges.length) {
      return;
    }
    setState(() {
      final RegisterRange range = _ranges.removeAt(index);
      _bank.removeRange(range.start, range.length);
    });
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
              child: Row(
                children: [
                  Expanded(flex: 2, child: _buildWritesPanel(writes)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _buildRangesPanel()),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _buildControlsPanel()),
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
            const Text('Memory State / Watch Ranges', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _ranges.length,
                itemBuilder: (BuildContext context, int index) {
                  final RegisterRange range = _ranges[index];
                  final List<int>? values = _bank.readRange(range.start, range.length);
                  final bool changed = values != null &&
                      List<int>.generate(range.length, (int i) => range.start + i)
                          .any((int addr) => _bank.isRecentlyChanged(addr, highlightWindow));
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
                                '${range.name} | ${range.start}..${range.start + range.length - 1}',
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
                        Text(values?.toString() ?? 'ERR', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  );
                },
              ),
            ),
            const Divider(),
            TextField(controller: _addNameController, decoration: const InputDecoration(labelText: 'Range name')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addStartController,
                    decoration: const InputDecoration(labelText: 'Start addr'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _addLenController,
                    decoration: const InputDecoration(labelText: 'Length'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FilledButton(onPressed: _addRange, child: const Text('Add range')),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsPanel() {
    Widget control(String title, int addr, TextEditingController controller) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Addr: 0x${addr.toRadixString(16).toUpperCase()} ($addr)', style: const TextStyle(fontSize: 11)),
            TextField(controller: controller),
            const SizedBox(height: 4),
            FilledButton(onPressed: () => _writeByControl(addr, controller), child: const Text('Write')),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ListView(
          children: [
            const Text('Controls (Simulate Robot)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            control('Robot Mode', addrMode, _modeController),
            control('Movement Status', addrMoveStatus, _moveController),
            control('Alarm Number', addrAlarm, _alarmController),
            control('IO Inputs [10 words]', addrIoIn, _ioInController),
            control('World Position [16 words]', addrWorld, _worldController),
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
