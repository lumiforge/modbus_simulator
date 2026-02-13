import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

void main() {
  runApp(const ModbusSimulatorApp());
}

class ModbusSimulatorApp extends StatelessWidget {
  const ModbusSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Modbus TCP Simulator',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const ModbusControlPanel(),
    );
  }
}

class HoldingRegisterBank {
  HoldingRegisterBank(this.size) : _values = List<int>.filled(size, 0);

  final int size;
  final List<int> _values;
  final Map<int, DateTime> _changedAt = <int, DateTime>{};

  List<int>? readRange(int start, int count) {
    if (!_isInRange(start, count)) {
      return null;
    }
    return List<int>.from(_values.getRange(start, start + count));
  }

  bool writeSingle(int address, int value) {
    if (!_isInRange(address, 1)) {
      return false;
    }
    _values[address] = value & 0xFFFF;
    _changedAt[address] = DateTime.now();
    return true;
  }

  bool writeMultiple(int start, List<int> values) {
    if (!_isInRange(start, values.length)) {
      return false;
    }
    for (int i = 0; i < values.length; i++) {
      _values[start + i] = values[i] & 0xFFFF;
      _changedAt[start + i] = DateTime.now();
    }
    return true;
  }

  int valueAt(int address) => _values[address];

  bool isRecentlyChanged(int address, Duration window) {
    final DateTime? changedAt = _changedAt[address];
    if (changedAt == null) {
      return false;
    }
    return DateTime.now().difference(changedAt) <= window;
  }

  bool _isInRange(int start, int count) {
    if (start < 0 || count <= 0) {
      return false;
    }
    return start + count <= size;
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
  ModbusTcpServer({
    required this.bank,
    required this.onRegistersChanged,
    required this.onLog,
  });

  final HoldingRegisterBank bank;
  final VoidCallback onRegistersChanged;
  final void Function(ModbusLogEntry entry) onLog;

  ServerSocket? _server;
  final List<Socket> _clients = <Socket>[];

  bool get isRunning => _server != null;

  Future<void> start({required int port, InternetAddress? address}) async {
    await stop();
    _server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: true,
    );

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
        onLog(
          ModbusLogEntry(
            timestamp: DateTime.now(),
            client: clientId,
            functionCode: functionCode,
            startAddress: 0,
            length: 0,
            result: 'exception',
          ),
        );
    }
  }

  void _handleReadHoldingRegisters(
    Socket client,
    int transactionId,
    int unitId,
    Uint8List pdu,
    String clientId,
  ) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int start = body.getUint16(1);
    final int count = body.getUint16(3);

    final List<int>? values = bank.readRange(start, count);
    if (values == null) {
      _sendException(client, transactionId, unitId, 3, 0x02);
      _log(clientId, 3, start, count, 'exception');
      return;
    }

    final BytesBuilder responsePdu = BytesBuilder();
    responsePdu
      ..addByte(3)
      ..addByte(count * 2);

    for (final int value in values) {
      responsePdu.add([(value >> 8) & 0xFF, value & 0xFF]);
    }

    _sendResponse(client, transactionId, unitId, responsePdu.toBytes());
    _log(clientId, 3, start, count, 'ok');
  }

  void _handleWriteSingleRegister(
    Socket client,
    int transactionId,
    int unitId,
    Uint8List pdu,
    String clientId,
  ) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int address = body.getUint16(1);
    final int value = body.getUint16(3);

    if (!bank.writeSingle(address, value)) {
      _sendException(client, transactionId, unitId, 6, 0x02);
      _log(clientId, 6, address, 1, 'exception');
      return;
    }

    _sendResponse(client, transactionId, unitId, pdu);
    _log(clientId, 6, address, 1, 'ok');
    onRegistersChanged();
  }

  void _handleWriteMultipleRegisters(
    Socket client,
    int transactionId,
    int unitId,
    Uint8List pdu,
    String clientId,
  ) {
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

    if (!bank.writeMultiple(start, values)) {
      _sendException(client, transactionId, unitId, 16, 0x02);
      _log(clientId, 16, start, count, 'exception');
      return;
    }

    final Uint8List responsePdu = Uint8List.fromList(<int>[
      16,
      (start >> 8) & 0xFF,
      start & 0xFF,
      (count >> 8) & 0xFF,
      count & 0xFF,
    ]);

    _sendResponse(client, transactionId, unitId, responsePdu);
    _log(clientId, 16, start, count, 'ok');
    onRegistersChanged();
  }

  void _sendException(
    Socket client,
    int transactionId,
    int unitId,
    int function,
    int exceptionCode,
  ) {
    final Uint8List pdu = Uint8List.fromList(<int>[function | 0x80, exceptionCode]);
    _sendResponse(client, transactionId, unitId, pdu);
  }

  void _sendResponse(Socket client, int transactionId, int unitId, Uint8List pdu) {
    final int length = pdu.length + 1;
    final BytesBuilder frame = BytesBuilder();
    frame
      ..add([(transactionId >> 8) & 0xFF, transactionId & 0xFF])
      ..add([0x00, 0x00])
      ..add([(length >> 8) & 0xFF, length & 0xFF])
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

class ModbusControlPanel extends StatefulWidget {
  const ModbusControlPanel({super.key});

  @override
  State<ModbusControlPanel> createState() => _ModbusControlPanelState();
}

class _ModbusControlPanelState extends State<ModbusControlPanel> {
  static const int defaultBankSize = 10000;
  static const Duration highlightWindow = Duration(seconds: 5);

  late final HoldingRegisterBank _bank;
  late final ModbusTcpServer _server;
  late final Timer _highlightTimer;

  final TextEditingController _addressController = TextEditingController(text: '0');
  final TextEditingController _countController = TextEditingController(text: '10');
  final TextEditingController _portController = TextEditingController(text: '1502');

  int _address = 0;
  int _count = 10;
  int _port = 1502;
  String _status = 'Stopped';
  final List<ModbusLogEntry> _logs = <ModbusLogEntry>[];

  @override
  void initState() {
    super.initState();
    _bank = HoldingRegisterBank(defaultBankSize);
    _server = ModbusTcpServer(
      bank: _bank,
      onRegistersChanged: _refresh,
      onLog: _appendLog,
    );

    _highlightTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    _startServer();
  }

  @override
  void dispose() {
    _highlightTimer.cancel();
    _addressController.dispose();
    _countController.dispose();
    _portController.dispose();
    _server.stop();
    super.dispose();
  }

  Future<void> _startServer() async {
    try {
      await _server.start(port: _port);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Running on port $_port';
      });
    } on SocketException catch (e) {
      setState(() {
        _status = 'Start error: ${e.message}';
      });
    }
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

  void _appendLog(ModbusLogEntry entry) {
    if (!mounted) {
      return;
    }
    setState(() {
      _logs.insert(0, entry);
      if (_logs.length > 200) {
        _logs.removeLast();
      }
    });
  }

  void _refresh() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _applyViewSettings() {
    final int? parsedAddress = int.tryParse(_addressController.text);
    final int? parsedCount = int.tryParse(_countController.text);

    if (parsedAddress == null || parsedAddress < 0 || parsedAddress >= _bank.size) {
      return;
    }
    if (parsedCount == null || parsedCount < 1 || parsedCount > 50) {
      return;
    }

    setState(() {
      _address = parsedAddress;
      final int maxCount = _bank.size - _address;
      _count = parsedCount > maxCount ? maxCount : parsedCount;
    });
  }

  Future<void> _applyPortAndRestart() async {
    final int? parsedPort = int.tryParse(_portController.text);
    if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
      return;
    }

    _port = parsedPort;
    await _startServer();
  }

  Future<void> _editRegister(int address) async {
    final TextEditingController editor = TextEditingController(
      text: _bank.valueAt(address).toString(),
    );

    final int? value = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit register $address'),
          content: TextField(
            controller: editor,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'uint16 value (0..65535)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final int? parsed = int.tryParse(editor.text);
                if (parsed == null || parsed < 0 || parsed > 65535) {
                  return;
                }
                Navigator.of(context).pop(parsed);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (value == null) {
      return;
    }

    _bank.writeSingle(address, value);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final int end = (_address + _count).clamp(0, _bank.size);
    final List<int> visibleAddresses = List<int>.generate(end - _address, (int i) => _address + i);

    return Scaffold(
      appBar: AppBar(title: const Text('Modbus TCP Server Simulator')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
                FilledButton(
                  onPressed: _applyPortAndRestart,
                  child: const Text('Start/Restart'),
                ),
                OutlinedButton(onPressed: _stopServer, child: const Text('Stop')),
                Text(_status),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _addressController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Address (0-based)'),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _countController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Count (1..50)'),
                  ),
                ),
                FilledButton(onPressed: _applyViewSettings, child: const Text('Refresh')),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Card(
                      child: Column(
                        children: [
                          const ListTile(title: Text('Holding registers')),
                          Expanded(
                            child: ListView.builder(
                              itemCount: visibleAddresses.length,
                              itemBuilder: (BuildContext context, int index) {
                                final int address = visibleAddresses[index];
                                final int value = _bank.valueAt(address);
                                final bool changed = _bank.isRecentlyChanged(address, highlightWindow);
                                final Color? rowColor = changed
                                    ? Colors.yellow.withValues(alpha: 0.25)
                                    : null;

                                return InkWell(
                                  onTap: () => _editRegister(address),
                                  child: Container(
                                    color: rowColor,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(child: Text('$address')),
                                        Expanded(child: Text('$value')),
                                        Expanded(child: Text('0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}')),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: Card(
                      child: Column(
                        children: [
                          const ListTile(title: Text('Request log')),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _logs.length,
                              itemBuilder: (BuildContext context, int index) {
                                final ModbusLogEntry entry = _logs[index];
                                final String timestamp =
                                    '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
                                    '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
                                    '${entry.timestamp.second.toString().padLeft(2, '0')}';

                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    '$timestamp ${entry.client} FC${entry.functionCode.toString().padLeft(2, '0')}',
                                  ),
                                  subtitle: Text(
                                    'addr=${entry.startAddress} len=${entry.length} ${entry.result}',
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
