import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

const int modbusPortDefault = 1502;
const int uiTailKeep = 2000;

void main() {
  runApp(const ModbusSimulatorApp());
}

enum StartupAction { loadConfig, createServer }

enum RegisterAccess { read, write, readWrite }

enum ByteOrderMode { bigEndian, byteSwap, wordSwap, wordByteSwap }

extension ByteOrderModeX on ByteOrderMode {
  String get yamlValue {
    switch (this) {
      case ByteOrderMode.bigEndian:
        return 'big_endian';
      case ByteOrderMode.byteSwap:
        return 'byte_swap';
      case ByteOrderMode.wordSwap:
        return 'word_swap';
      case ByteOrderMode.wordByteSwap:
        return 'word_byte_swap';
    }
  }

  String get title {
    switch (this) {
      case ByteOrderMode.bigEndian:
        return 'Big Endian (ABCD)';
      case ByteOrderMode.byteSwap:
        return 'Byte swap (BADC)';
      case ByteOrderMode.wordSwap:
        return 'Word swap (CDAB)';
      case ByteOrderMode.wordByteSwap:
        return 'Word + Byte swap (DCBA)';
    }
  }
}

class ModbusSimulatorApp extends StatelessWidget {
  const ModbusSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Borunte Emulator',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: const StartupScreen(),
    );
  }
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  bool _scanInProgress = false;
  bool _scanCancelRequested = false;
  String _scanStatus = 'Сканирование ещё не запускалось';
  final List<String> _activeHosts = <String>[];

  Future<void> _runLanScan() async {
    setState(() {
      _scanInProgress = true;
      _scanCancelRequested = false;
      _scanStatus = 'Идёт сканирование локальной сети...';
      _activeHosts.clear();
    });

    try {
      final String? subnet = await _detectPrivateSubnetPrefix();
      if (subnet == null) {
        setState(() {
          _scanStatus = 'Не удалось определить локальную подсеть';
        });
        return;
      }

      for (int i = 1; i <= 254; i++) {
        if (_scanCancelRequested) {
          break;
        }

        final String host = '$subnet.$i';
        if (await _pingHost(host)) {
          _activeHosts.add(host);
          if (mounted) {
            setState(() {
              _scanStatus =
                  'Найдено активных устройств: ${_activeHosts.length}';
            });
          }
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        if (_scanCancelRequested) {
          _scanStatus = _activeHosts.isEmpty
              ? 'Сканирование остановлено пользователем'
              : 'Сканирование остановлено: найдено ${_activeHosts.length} устройств';
          return;
        }

        _scanStatus = _activeHosts.isEmpty
            ? 'Активные устройства не найдены в подсети $subnet.0/24'
            : 'Сканирование завершено: ${_activeHosts.length} устройств';
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanInProgress = false;
        });
      }
    }
  }

  void _cancelLanScan() {
    if (!_scanInProgress || _scanCancelRequested) {
      return;
    }

    setState(() {
      _scanCancelRequested = true;
      _scanStatus = 'Останавливаем сканирование...';
    });
  }

  Future<String?> _detectPrivateSubnetPrefix() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    for (final NetworkInterface iface in interfaces) {
      for (final InternetAddress address in iface.addresses) {
        final List<String> octets = address.address.split('.');
        if (octets.length != 4) {
          continue;
        }

        final int first = int.tryParse(octets[0]) ?? -1;
        final int second = int.tryParse(octets[1]) ?? -1;
        final bool isPrivate =
            first == 10 ||
            (first == 172 && second >= 16 && second <= 31) ||
            (first == 192 && second == 168);
        if (isPrivate) {
          return '${octets[0]}.${octets[1]}.${octets[2]}';
        }
      }
    }

    return null;
  }

  Future<bool> _pingHost(String host) async {
    final List<String> args;
    if (Platform.isWindows) {
      args = <String>['-n', '1', '-w', '120', host];
    } else {
      args = <String>['-c', '1', '-W', '1', host];
    }

    final ProcessResult result = await Process.run('ping', args);
    return result.exitCode == 0;
  }

  void _openDashboard(StartupAction action) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ModbusDashboard(startupAction: action),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modbus Simulator — старт')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Выберите режим работы',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => _openDashboard(StartupAction.loadConfig),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Загрузить конфигурацию Modbus TCP'),
                ),
                FilledButton.icon(
                  onPressed: () => _openDashboard(StartupAction.createServer),
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Создать новый Modbus TCP сервер'),
                ),
                OutlinedButton.icon(
                  onPressed: _scanInProgress ? null : _runLanScan,
                  icon: const Icon(Icons.network_ping),
                  label: const Text('Сканировать локальную сеть'),
                ),
                OutlinedButton.icon(
                  onPressed: _scanInProgress ? _cancelLanScan : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Завершить сканирование'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(_scanStatus),
            const SizedBox(height: 8),
            if (_scanInProgress) const LinearProgressIndicator(),
            if (_activeHosts.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              const Text(
                'Активные устройства:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _activeHosts.length,
                  itemBuilder: (BuildContext context, int index) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.computer),
                    title: Text(_activeHosts[index]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
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

  String get label =>
      '$name (0x${start.toRadixString(16).toUpperCase().padLeft(4, '0')})';

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
        final int byteValue = valueIndex == 0
            ? rawWord & 0xFF
            : (rawWord >> 8) & 0xFF;
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

  void addWrite({
    required int unitId,
    required int addr,
    required List<int> values,
  }) {
    _seq += 1;
    _tail.add(
      WriteEvent(
        seq: _seq,
        ts: DateTime.now(),
        unitId: unitId,
        addr: addr,
        values: values,
      ),
    );
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

  bool _validate(
    int start,
    int count, {
    required bool forWrite,
    bool enforceWriteAccess = true,
  }) {
    if (count <= 0 || start < 0) {
      return false;
    }
    for (int i = 0; i < count; i++) {
      final int addr = start + i;
      final RegisterAccess? access = _accessByAddress[addr];
      if (access == null) {
        return false;
      }
      if (forWrite && enforceWriteAccess && access == RegisterAccess.read) {
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

  bool writeSingle(
    int unitId,
    int address,
    int value, {
    bool enforceAccess = false,
  }) {
    if (!_validate(
      address,
      1,
      forWrite: true,
      enforceWriteAccess: enforceAccess,
    )) {
      return false;
    }
    _values[address] = value & 0xFFFF;
    _changedAt[address] = DateTime.now();
    onWrite(unitId, address, <int>[value & 0xFFFF]);
    return true;
  }

  bool writeMultiple(
    int unitId,
    int start,
    List<int> values, {
    bool enforceAccess = false,
  }) {
    if (!_validate(
      start,
      values.length,
      forWrite: true,
      enforceWriteAccess: enforceAccess,
    )) {
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
    required this.mbapHeader,
    required this.modbusRequest,
    required this.requestApu,
  });

  final DateTime timestamp;
  final String client;
  final int functionCode;
  final int startAddress;
  final int length;
  final String result;
  final String mbapHeader;
  final String modbusRequest;
  final String requestApu;
}

class ModbusTcpServer {
  ModbusTcpServer({
    required this.bank,
    required this.onRegistersChanged,
    required this.onLog,
    required this.serverId,
    required this.addressOffset,
  });

  final SparseHoldingRegisterBank bank;
  final VoidCallback onRegistersChanged;
  final void Function(ModbusLogEntry entry) onLog;
  final int serverId;
  final int addressOffset;

  ServerSocket? _server;
  final List<Socket> _clients = <Socket>[];
  final Map<Socket, BytesBuilder> _buffers = <Socket, BytesBuilder>{};

  Future<void> start({required int port, InternetAddress? address}) async {
    await stop();
    _server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: true,
    );
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
    if (unitId != serverId) {
      return;
    }
    final Uint8List pdu = Uint8List.sublistView(data, 7, 6 + length);
    if (pdu.isEmpty) {
      return;
    }

    final int functionCode = pdu[0];
    final String clientId =
        '${client.remoteAddress.address}:${client.remotePort}';
    final ByteData header = ByteData.sublistView(data, 0, 6);
    final String mbapHeader =
        'TID=0x${header.getUint16(0).toRadixString(16).toUpperCase().padLeft(4, '0')} '
        'PID=0x${header.getUint16(2).toRadixString(16).toUpperCase().padLeft(4, '0')} '
        'LEN=0x${header.getUint16(4).toRadixString(16).toUpperCase().padLeft(4, '0')} '
        'UID=0x${unitId.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    final String modbusRequest =
        'FC=0x${functionCode.toRadixString(16).toUpperCase().padLeft(2, '0')} '
        'PDU=${_formatBytesHex(pdu)}';
    final String requestApu = _formatBytesHex(data);

    switch (functionCode) {
      case 3:
        _handleReadHoldingRegisters(
          client,
          transactionId,
          unitId,
          pdu,
          clientId,
          mbapHeader,
          modbusRequest,
          requestApu,
        );
        break;
      case 6:
        _handleWriteSingleRegister(
          client,
          transactionId,
          unitId,
          pdu,
          clientId,
          mbapHeader,
          modbusRequest,
          requestApu,
        );
        break;
      case 16:
        _handleWriteMultipleRegisters(
          client,
          transactionId,
          unitId,
          pdu,
          clientId,
          mbapHeader,
          modbusRequest,
          requestApu,
        );
        break;
      default:
        _sendException(client, transactionId, unitId, functionCode, 0x01);
        _log(
          clientId,
          functionCode,
          0,
          0,
          'exception',
          mbapHeader,
          modbusRequest,
          requestApu,
        );
    }
  }

  void _handleReadHoldingRegisters(
    Socket client,
    int tid,
    int unitId,
    Uint8List pdu,
    String clientId,
    String mbapHeader,
    String modbusRequest,
    String requestApu,
  ) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int requestedStart = body.getUint16(1);
    final int start = requestedStart - addressOffset;
    final int count = body.getUint16(3);

    final List<int>? values = bank.readRange(start, count);
    if (values == null) {
      _sendException(client, tid, unitId, 3, 0x02);
      _log(
        clientId,
        3,
        start,
        count,
        'exception',
        mbapHeader,
        modbusRequest,
        requestApu,
      );
      return;
    }

    final BytesBuilder responsePdu = BytesBuilder();
    responsePdu
      ..addByte(3)
      ..addByte(count * 2);
    for (final int value in values) {
      responsePdu.add(<int>[(value >> 8) & 0xFF, value & 0xFF]);
    }

    _sendResponse(client, tid, unitId, responsePdu.toBytes());
    _log(
      clientId,
      3,
      start,
      count,
      'ok',
      mbapHeader,
      modbusRequest,
      requestApu,
    );
  }

  void _handleWriteSingleRegister(
    Socket client,
    int tid,
    int unitId,
    Uint8List pdu,
    String clientId,
    String mbapHeader,
    String modbusRequest,
    String requestApu,
  ) {
    if (pdu.length != 5) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int address = body.getUint16(1) - addressOffset;
    final int value = body.getUint16(3);

    if (!bank.writeSingle(unitId, address, value, enforceAccess: true)) {
      _sendException(client, tid, unitId, 6, 0x02);
      _log(
        clientId,
        6,
        address,
        1,
        'exception',
        mbapHeader,
        modbusRequest,
        requestApu,
      );
      return;
    }

    _sendResponse(client, tid, unitId, pdu);
    _log(clientId, 6, address, 1, 'ok', mbapHeader, modbusRequest, requestApu);
    onRegistersChanged();
  }

  void _handleWriteMultipleRegisters(
    Socket client,
    int tid,
    int unitId,
    Uint8List pdu,
    String clientId,
    String mbapHeader,
    String modbusRequest,
    String requestApu,
  ) {
    if (pdu.length < 6) {
      return;
    }

    final ByteData body = ByteData.sublistView(pdu);
    final int requestedStart = body.getUint16(1);
    final int start = requestedStart - addressOffset;
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

    if (!bank.writeMultiple(unitId, start, values, enforceAccess: true)) {
      _sendException(client, tid, unitId, 16, 0x02);
      _log(
        clientId,
        16,
        start,
        count,
        'exception',
        mbapHeader,
        modbusRequest,
        requestApu,
      );
      return;
    }

    _sendResponse(
      client,
      tid,
      unitId,
      Uint8List.fromList(<int>[
        16,
        (requestedStart >> 8) & 0xFF,
        requestedStart & 0xFF,
        (count >> 8) & 0xFF,
        count & 0xFF,
      ]),
    );
    _log(
      clientId,
      16,
      start,
      count,
      'ok',
      mbapHeader,
      modbusRequest,
      requestApu,
    );
    onRegistersChanged();
  }

  void _sendException(
    Socket client,
    int tid,
    int unitId,
    int function,
    int exceptionCode,
  ) {
    _sendResponse(
      client,
      tid,
      unitId,
      Uint8List.fromList(<int>[function | 0x80, exceptionCode]),
    );
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

  String _formatBytesHex(Uint8List bytes) {
    return bytes
        .map((int b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
  }

  void _log(
    String clientId,
    int fc,
    int start,
    int len,
    String result,
    String mbapHeader,
    String modbusRequest,
    String requestApu,
  ) {
    onLog(
      ModbusLogEntry(
        timestamp: DateTime.now(),
        client: clientId,
        functionCode: fc,
        startAddress: start,
        length: len,
        result: result,
        mbapHeader: mbapHeader,
        modbusRequest: modbusRequest,
        requestApu: requestApu,
      ),
    );
  }
}

class ModbusDashboard extends StatefulWidget {
  const ModbusDashboard({required this.startupAction, super.key});

  final StartupAction startupAction;

  @override
  State<ModbusDashboard> createState() => _ModbusDashboardState();
}

class _ModbusDashboardState extends State<ModbusDashboard> {
  static const Duration highlightWindow = Duration(seconds: 5);

  late final SparseHoldingRegisterBank _bank;
  ModbusTcpServer? _server;
  late final Timer _uiTimer;
  Timer? _requestLogUiTimer;
  final EventSink _sink = EventSink();

  final List<RegisterRange> _ranges = <RegisterRange>[];
  final Map<int, List<TextEditingController>> _rangeValueControllers =
      <int, List<TextEditingController>>{};
  final Map<int, List<FocusNode>> _rangeValueFocusNodes =
      <int, List<FocusNode>>{};

  final TextEditingController _serverNameController = TextEditingController(
    text: 'Modbus Simulator',
  );
  final TextEditingController _portController = TextEditingController(
    text: '$modbusPortDefault',
  );
  final TextEditingController _serverIdController = TextEditingController(
    text: '1',
  );

  final List<ModbusLogEntry> _requestLog = <ModbusLogEntry>[];
  List<ModbusLogEntry> _requestLogView = <ModbusLogEntry>[];
  bool _logsVisible = false;
  bool _requestLogPaused = false;

  bool get _useImmediateMouseDrag =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  int _port = modbusPortDefault;
  int _serverId = 1;
  int _addressOffset = 0;
  ByteOrderMode _byteOrderMode = ByteOrderMode.bigEndian;
  String _serverName = 'Modbus Simulator';
  String _status = 'Stopped';

  @override
  void initState() {
    super.initState();
    _bank = SparseHoldingRegisterBank((int unitId, int addr, List<int> values) {
      _sink.addWrite(unitId: unitId, addr: addr, values: values);
    });

    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    if (widget.startupAction == StartupAction.createServer) {
      _startServer();
    } else {
      unawaited(_prepareDashboardWithConfig());
    }
  }

  Future<void> _prepareDashboardWithConfig() async {
    await _importConfigFromYaml();
    if (_ranges.isNotEmpty) {
      await _startServer();
    }
  }

  @override
  void dispose() {
    _uiTimer.cancel();
    _requestLogUiTimer?.cancel();
    _server?.stop();
    _serverNameController.dispose();
    _portController.dispose();
    _serverIdController.dispose();
    for (final List<TextEditingController> controllers
        in _rangeValueControllers.values) {
      for (final TextEditingController controller in controllers) {
        controller.dispose();
      }
    }
    for (final List<FocusNode> nodes in _rangeValueFocusNodes.values) {
      for (final FocusNode node in nodes) {
        node.dispose();
      }
    }
    super.dispose();
  }

  void _addReqLog(ModbusLogEntry entry) {
    _requestLog.insert(0, entry);
    if (_requestLog.length > 200) {
      _requestLog.removeLast();
    }

    if (!_requestLogPaused) {
      _requestLogView = List<ModbusLogEntry>.from(_requestLog);
    }

    if (!mounted || !_logsVisible) {
      return;
    }

    if (_requestLogUiTimer?.isActive ?? false) {
      return;
    }

    _requestLogUiTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted && _logsVisible && !_requestLogPaused) {
        setState(() {});
      }
    });
  }

  void _toggleRequestLogPause() {
    setState(() {
      _requestLogPaused = !_requestLogPaused;
      if (!_requestLogPaused) {
        _requestLogView = List<ModbusLogEntry>.from(_requestLog);
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
      final List<TextEditingController>? controllers =
          _rangeValueControllers[range.start];
      final List<FocusNode>? focusNodes = _rangeValueFocusNodes[range.start];
      if (controllers == null || focusNodes == null) {
        continue;
      }
      final List<int>? values = _bank.readRangeRaw(
        range.start,
        range.storageLength,
      );
      if (values == null || values.length != controllers.length) {
        continue;
      }
      for (int i = 0; i < controllers.length; i++) {
        if (focusNodes[i].hasFocus) {
          continue;
        }
        final String text = values[i].toString();
        if (controllers[i].text != text) {
          controllers[i].text = text;
        }
      }
    }
  }

  void _ensureRangeInputControllers(RegisterRange range) {
    final int len = range.storageLength;
    final List<int> values =
        _bank.readRangeRaw(range.start, len) ?? List<int>.filled(len, 0);
    final List<TextEditingController>? existing =
        _rangeValueControllers[range.start];
    final List<FocusNode>? existingNodes = _rangeValueFocusNodes[range.start];
    if (existing != null &&
        existing.length == len &&
        existingNodes != null &&
        existingNodes.length == len) {
      return;
    }

    if (existing != null) {
      for (final TextEditingController controller in existing) {
        controller.dispose();
      }
    }
    if (existingNodes != null) {
      for (final FocusNode node in existingNodes) {
        node.dispose();
      }
    }

    _rangeValueControllers[range.start] = List<TextEditingController>.generate(
      len,
      (int i) => TextEditingController(text: values[i].toString()),
    );
    _rangeValueFocusNodes[range.start] = List<FocusNode>.generate(
      len,
      (_) => FocusNode(),
    );
  }

  Future<void> _startServer() async {
    try {
      _server ??= ModbusTcpServer(
        bank: _bank,
        onRegistersChanged: _refresh,
        onLog: _addReqLog,
        serverId: _serverId,
        addressOffset: _addressOffset,
      );
      await _server!.start(port: _port);
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
    final int? parsedServerId = int.tryParse(_serverIdController.text);
    if (parsedServerId == null || parsedServerId < 0 || parsedServerId > 255) {
      return;
    }

    _port = parsedPort;
    _serverId = parsedServerId;
    _serverName = _serverNameController.text.trim().isEmpty
        ? 'Modbus Simulator'
        : _serverNameController.text.trim();
    await _server?.stop();
    _server = ModbusTcpServer(
      bank: _bank,
      onRegistersChanged: _refresh,
      onLog: _addReqLog,
      serverId: _serverId,
      addressOffset: _addressOffset,
    );
    await _startServer();
  }

  Future<void> _stopServer() async {
    await _server?.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Stopped';
    });
  }

  void _writeRangeValue(RegisterRange range) {
    final List<TextEditingController>? controllers =
        _rangeValueControllers[range.start];
    if (controllers == null || controllers.isEmpty) {
      return;
    }

    final List<int> values = <int>[];
    for (final TextEditingController controller in controllers) {
      final int? parsed = int.tryParse(controller.text.trim());
      if (parsed == null) {
        setState(() {
          _status = 'Ошибка: введите числовые значения для ${range.name}';
        });
        return;
      }
      values.add(parsed);
    }

    final bool ok = _bank.writeMultiple(0, range.start, values);
    if (ok) {
      _refresh();
    }
  }

  Future<void> _showBitEditor(RegisterRange range) async {
    final List<int>? values = await showDialog<List<int>>(
      context: context,
      builder: (BuildContext context) =>
          _BitEditorDialog(range: range, bank: _bank),
    );

    if (values == null) {
      return;
    }

    final bool ok = _bank.writeMultiple(0, range.start, values);
    if (ok) {
      _refresh();
    }
  }

  void _removeRange(int index) {
    if (index < 0 || index >= _ranges.length) {
      return;
    }
    setState(() {
      final RegisterRange range = _ranges.removeAt(index);
      _bank.removeRange(range.start, range.storageLength);
      final List<TextEditingController>? controllers = _rangeValueControllers
          .remove(range.start);
      if (controllers != null) {
        for (final TextEditingController controller in controllers) {
          controller.dispose();
        }
      }
      final List<FocusNode>? nodes = _rangeValueFocusNodes.remove(range.start);
      if (nodes != null) {
        for (final FocusNode node in nodes) {
          node.dispose();
        }
      }
    });
  }

  void _reorderRanges(int fromIndex, int toIndex) {
    if (fromIndex == toIndex ||
        fromIndex < 0 ||
        toIndex < 0 ||
        fromIndex >= _ranges.length ||
        toIndex >= _ranges.length) {
      return;
    }

    setState(() {
      final RegisterRange moved = _ranges.removeAt(fromIndex);
      final int insertIndex = toIndex > fromIndex ? toIndex - 1 : toIndex;
      _ranges.insert(insertIndex, moved);
    });
  }

  Future<void> _showAddRegisterDialog() async {
    final TextEditingController nameController = TextEditingController();
    final TextEditingController startController = TextEditingController();
    final TextEditingController lengthController = TextEditingController(
      text: '1',
    );
    final TextEditingController valueIndexController = TextEditingController(
      text: '0',
    );

    RegisterAccess access = RegisterAccess.readWrite;
    RegisterValueType valueType = RegisterValueType.word;

    final bool? shouldCreate = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Добавить регистр'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    controller: startController,
                    decoration: const InputDecoration(
                      labelText: 'Start address',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  DropdownButtonFormField<RegisterValueType>(
                    value: valueType,
                    decoration: const InputDecoration(labelText: 'Value type'),
                    items: RegisterValueType.values
                        .map(
                          (RegisterValueType type) =>
                              DropdownMenuItem<RegisterValueType>(
                                value: type,
                                child: Text(type.name),
                              ),
                        )
                        .toList(),
                    onChanged: (RegisterValueType? next) {
                      if (next != null) {
                        valueType = next;
                      }
                    },
                  ),
                  TextField(
                    controller: lengthController,
                    decoration: const InputDecoration(labelText: 'Word length'),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: valueIndexController,
                    decoration: const InputDecoration(
                      labelText: 'Bit/byte index',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  DropdownButtonFormField<RegisterAccess>(
                    value: access,
                    decoration: const InputDecoration(labelText: 'Access'),
                    items: RegisterAccess.values
                        .map(
                          (RegisterAccess nextAccess) =>
                              DropdownMenuItem<RegisterAccess>(
                                value: nextAccess,
                                child: Text(nextAccess.name),
                              ),
                        )
                        .toList(),
                    onChanged: (RegisterAccess? next) {
                      if (next != null) {
                        access = next;
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );

    if (shouldCreate != true || !mounted) {
      nameController.dispose();
      startController.dispose();
      lengthController.dispose();
      valueIndexController.dispose();
      return;
    }

    final int? start = int.tryParse(startController.text.trim());
    final int parsedLength = int.tryParse(lengthController.text.trim()) ?? 1;
    final int parsedValueIndex =
        int.tryParse(valueIndexController.text.trim()) ?? 0;
    final String parsedName = nameController.text.trim().isEmpty
        ? 'Register ${_ranges.length + 1}'
        : nameController.text.trim();
    final int storageLength = valueType == RegisterValueType.word
        ? parsedLength
        : 1;

    if (start == null || start < 0 || storageLength < 1) {
      if (mounted) {
        setState(() {
          _status = 'Ошибка: проверьте параметры нового регистра';
        });
      }
    } else {
      final RegisterRange range = RegisterRange(
        name: parsedName,
        start: start,
        access: access,
        length: parsedLength,
        valueType: valueType,
        valueIndex: parsedValueIndex,
      );
      final bool added = _bank.addRange(
        range.start,
        range.storageLength,
        range.access,
      );
      if (!added) {
        setState(() {
          _status = 'Ошибка: диапазон адресов уже занят';
        });
      } else {
        setState(() {
          _ranges.add(range);
          _ensureRangeInputControllers(range);
          _status = 'Добавлен регистр ${range.name} (${range.start})';
        });
      }
    }

    nameController.dispose();
    startController.dispose();
    lengthController.dispose();
    valueIndexController.dispose();
  }

  Future<String?> _selectYamlConfigPath() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'YAML', extensions: <String>['yaml', 'yml']),
      ],
      confirmButtonText: 'Выбрать',
    );

    return file?.path;
  }

  Future<String?> _selectYamlExportPath() async {
    final FileSaveLocation? saveLocation = await getSaveLocation(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'YAML', extensions: <String>['yaml', 'yml']),
      ],
      suggestedName: 'modbus_config.yaml',
    );
    return saveLocation?.path;
  }

  RegisterAccess? _parseYamlAccess(String value) {
    switch (value.trim()) {
      case 'read':
        return RegisterAccess.read;
      case 'write':
        return RegisterAccess.write;
      case 'read_write':
        return RegisterAccess.readWrite;
      default:
        return null;
    }
  }

  ByteOrderMode? _parseYamlByteOrder(String value) {
    switch (value.trim()) {
      case 'big_endian':
        return ByteOrderMode.bigEndian;
      case 'byte_swap':
        return ByteOrderMode.byteSwap;
      case 'word_swap':
        return ByteOrderMode.wordSwap;
      case 'word_byte_swap':
        return ByteOrderMode.wordByteSwap;
      default:
        return null;
    }
  }

  Map<String, String> _parseYamlConfigMeta(String content) {
    final Map<String, String> meta = <String, String>{};
    for (final String rawLine in LineSplitter.split(content)) {
      final String line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('#') ||
          line.startsWith('- ') ||
          line == 'inputs:' ||
          line.startsWith('inputs:')) {
        continue;
      }
      if (rawLine.startsWith(' ') || rawLine.startsWith('	')) {
        continue;
      }
      final int split = line.indexOf(':');
      if (split <= 0) {
        continue;
      }
      final String key = line.substring(0, split).trim();
      final String value = line.substring(split + 1).trim();
      if (key.isNotEmpty) {
        meta[key] = value;
      }
    }
    return meta;
  }

  RegisterValueType? _parseYamlValueType(String value) {
    switch (value.trim()) {
      case 'bit':
        return RegisterValueType.bit;
      case 'byte':
        return RegisterValueType.byte;
      case 'word':
        return RegisterValueType.word;
      default:
        return null;
    }
  }

  String _yamlEscapeSingleQuoted(String value) {
    return value.replaceAll("'", "''");
  }

  String _yamlAccessValue(RegisterAccess access) {
    switch (access) {
      case RegisterAccess.read:
        return 'read';
      case RegisterAccess.write:
        return 'write';
      case RegisterAccess.readWrite:
        return 'read_write';
    }
  }

  String _yamlValueType(RegisterValueType type) {
    switch (type) {
      case RegisterValueType.bit:
        return 'bit';
      case RegisterValueType.byte:
        return 'byte';
      case RegisterValueType.word:
        return 'word';
    }
  }

  List<Map<String, String>> _parseInputItems(String content) {
    final List<Map<String, String>> items = <Map<String, String>>[];
    Map<String, String>? current;

    for (final String rawLine in LineSplitter.split(content)) {
      final String line = rawLine.trimRight();
      final String trimmed = line.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed == 'inputs:') {
        continue;
      }

      if (trimmed.startsWith('- ')) {
        final Map<String, String> item = <String, String>{};
        final String rest = trimmed.substring(2).trim();
        if (rest.contains(':')) {
          final int split = rest.indexOf(':');
          item[rest.substring(0, split).trim()] = rest
              .substring(split + 1)
              .trim();
        }
        items.add(item);
        current = item;
        continue;
      }

      if (current == null || !trimmed.contains(':')) {
        continue;
      }
      final int split = trimmed.indexOf(':');
      current[trimmed.substring(0, split).trim()] = trimmed
          .substring(split + 1)
          .trim();
    }

    return items;
  }

  String _parseYamlName(String value) {
    final String trimmed = value.trim();
    if (trimmed.length >= 2 &&
        trimmed.startsWith("'") &&
        trimmed.endsWith("'")) {
      return trimmed.substring(1, trimmed.length - 1).replaceAll("''", "'");
    }
    return trimmed;
  }

  List<int> _parseYamlValues(String valuesRaw) {
    final String trimmed = valuesRaw.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      return <int>[];
    }
    final String inner = trimmed.substring(1, trimmed.length - 1).trim();
    if (inner.isEmpty) {
      return <int>[];
    }
    return inner.split(',').map((String e) => int.parse(e.trim())).toList();
  }

  Future<void> _exportConfigToYaml() async {
    final String? selectedPath = await _selectYamlExportPath();
    if (selectedPath == null || selectedPath.trim().isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Экспорт отменён';
      });
      return;
    }

    try {
      final StringBuffer yaml = StringBuffer()
        ..writeln("server_name: '${_yamlEscapeSingleQuoted(_serverName)}'")
        ..writeln('port: $_port')
        ..writeln('server_id: $_serverId')
        ..writeln('byte_order: ${_byteOrderMode.yamlValue}')
        ..writeln('address_offset: $_addressOffset')
        ..writeln('inputs:');

      for (final RegisterRange range in _ranges) {
        final List<int> values =
            _bank.readRangeRaw(range.start, range.storageLength) ??
            List<int>.filled(range.storageLength, 0);
        yaml
          ..writeln("  - name: '${_yamlEscapeSingleQuoted(range.name)}'")
          ..writeln('    address: ${range.start}')
          ..writeln('    access: ${_yamlAccessValue(range.access)}')
          ..writeln('    length: ${range.length}')
          ..writeln('    value_type: ${_yamlValueType(range.valueType)}')
          ..writeln('    index: ${range.valueIndex}')
          ..writeln('    values: [${values.join(', ')}]');
      }

      final File output = File(selectedPath.trim());
      await output.writeAsString(yaml.toString());

      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Конфигурация сохранена в ${output.path}';
      });
    } on FileSystemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Ошибка экспорта: ${e.message}';
      });
    }
  }

  Future<void> _importConfigFromYaml() async {
    final String? selectedPath = await _selectYamlConfigPath();
    if (selectedPath == null || selectedPath.trim().isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Выбор файла отменён';
      });
      return;
    }

    final String rawPath = selectedPath.trim();

    try {
      final File input = File(rawPath);
      final String content = await input.readAsString();
      final Map<String, String> meta = _parseYamlConfigMeta(content);
      final List<Map<String, String>> items = _parseInputItems(content);
      if (items.isEmpty) {
        setState(() {
          _status = 'Import error: inputs не найдены в YAML';
        });
        return;
      }

      final int configPort = int.tryParse((meta['port'] ?? '').trim()) ?? _port;
      final int configServerId =
          int.tryParse((meta['server_id'] ?? meta['slave_id'] ?? '').trim()) ??
          _serverId;
      final int configAddressOffset =
          int.tryParse((meta['address_offset'] ?? '').trim()) ?? _addressOffset;
      final ByteOrderMode configByteOrder =
          _parseYamlByteOrder(meta['byte_order'] ?? '') ?? _byteOrderMode;
      final String configServerNameRaw = _parseYamlName(
        meta['server_name'] ?? '',
      ).trim();
      final String configServerName = configServerNameRaw.isEmpty
          ? _serverName
          : configServerNameRaw;

      if (configPort < 1 ||
          configPort > 65535 ||
          configServerId < 0 ||
          configServerId > 255 ||
          (configAddressOffset != 0 && configAddressOffset != 1)) {
        setState(() {
          _status = 'Ошибка импорта: неверные настройки сервера в YAML';
        });
        return;
      }

      final List<RegisterRange> importedRanges = <RegisterRange>[];
      final Map<int, List<int>> importedValues = <int, List<int>>{};

      for (final Map<String, String> item in items) {
        final String name = _parseYamlName(item['name'] ?? '');
        final int? address = int.tryParse((item['address'] ?? '').trim());
        final RegisterAccess? access = _parseYamlAccess(item['access'] ?? '');
        final RegisterValueType? type = _parseYamlValueType(
          item['value_type'] ?? '',
        );
        final int length = int.tryParse((item['length'] ?? '').trim()) ?? 1;
        final int index = int.tryParse((item['index'] ?? '').trim()) ?? 0;

        if (name.isEmpty ||
            address == null ||
            address < 0 ||
            access == null ||
            type == null ||
            length < 1 ||
            index < 0) {
          setState(() {
            _status = 'Ошибка импорта: некорректная запись в YAML';
          });
          return;
        }

        final int safeLength = type == RegisterValueType.word ? length : 1;
        final RegisterRange range = RegisterRange(
          name: name,
          start: address,
          access: access,
          length: safeLength,
          valueType: type,
          valueIndex: index,
        );
        importedRanges.add(range);

        if (item.containsKey('values')) {
          importedValues[address] = _parseYamlValues(item['values']!);
        }
      }

      for (final RegisterRange range in _ranges) {
        _bank.removeRange(range.start, range.storageLength);
      }
      for (final List<TextEditingController> controllers
          in _rangeValueControllers.values) {
        for (final TextEditingController controller in controllers) {
          controller.dispose();
        }
      }
      for (final List<FocusNode> nodes in _rangeValueFocusNodes.values) {
        for (final FocusNode node in nodes) {
          node.dispose();
        }
      }
      _rangeValueControllers.clear();
      _rangeValueFocusNodes.clear();
      _ranges.clear();

      for (final RegisterRange range in importedRanges) {
        final bool added = _bank.addRange(
          range.start,
          range.storageLength,
          range.access,
        );
        if (!added) {
          setState(() {
            _status = 'Ошибка импорта: пересечение адресов в YAML';
          });
          return;
        }
        final List<int> initial = importedValues[range.start] ?? <int>[];
        if (initial.isNotEmpty) {
          final List<int> valuesToWrite = initial
              .take(range.storageLength)
              .toList();
          if (valuesToWrite.length < range.storageLength) {
            valuesToWrite.addAll(
              List<int>.filled(range.storageLength - valuesToWrite.length, 0),
            );
          }
          _bank.writeMultiple(0, range.start, valuesToWrite);
        }
        _ranges.add(range);
        _ensureRangeInputControllers(range);
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _port = configPort;
        _serverId = configServerId;
        _addressOffset = configAddressOffset;
        _byteOrderMode = configByteOrder;
        _serverName = configServerName;
        _portController.text = '$_port';
        _serverIdController.text = '$_serverId';
        _serverNameController.text = _serverName;
        _status = 'Импортировано ${_ranges.length} регистров из ${input.path}';
      });
    } on FileSystemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Ошибка импорта: ${e.message}';
      });
    } on FormatException {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Ошибка импорта: неверный формат YAML';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<WriteEvent> writes = _sink.getTail(limit: 50);

    return Scaffold(
      appBar: AppBar(title: Text(_serverName)),
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
                  width: 220,
                  child: TextField(
                    controller: _serverNameController,
                    decoration: const InputDecoration(labelText: 'Server name'),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _serverIdController,
                    decoration: const InputDecoration(
                      labelText: 'Server ID (Slave ID)',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<ByteOrderMode>(
                    value: _byteOrderMode,
                    decoration: const InputDecoration(labelText: 'Byte Order'),
                    items: ByteOrderMode.values
                        .map(
                          (ByteOrderMode mode) =>
                              DropdownMenuItem<ByteOrderMode>(
                                value: mode,
                                child: Text(mode.title),
                              ),
                        )
                        .toList(),
                    onChanged: (ByteOrderMode? mode) {
                      if (mode == null) {
                        return;
                      }
                      setState(() {
                        _byteOrderMode = mode;
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<int>(
                    value: _addressOffset,
                    decoration: const InputDecoration(
                      labelText: 'Address Offset',
                    ),
                    items: const <DropdownMenuItem<int>>[
                      DropdownMenuItem<int>(value: 0, child: Text('0')),
                      DropdownMenuItem<int>(value: 1, child: Text('1')),
                    ],
                    onChanged: (int? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _addressOffset = value;
                      });
                    },
                  ),
                ),
                FilledButton(
                  onPressed: _restartServer,
                  child: const Text('Start/Restart'),
                ),
                OutlinedButton(
                  onPressed: _stopServer,
                  child: const Text('Stop'),
                ),
                FilledButton.icon(
                  onPressed: _importConfigFromYaml,
                  icon: const Icon(Icons.download),
                  label: const Text('Импорт YAML'),
                ),
                OutlinedButton.icon(
                  onPressed: _exportConfigToYaml,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Экспорт YAML'),
                ),
                Text(_status),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildRangesPanel()),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _logsVisible = !_logsVisible;
                  });
                },
                icon: Icon(
                  _logsVisible
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                ),
                label: Text(_logsVisible ? 'Скрыть логи' : 'Открыть логи'),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              height: _logsVisible ? 260 : 0,
              child: _logsVisible
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _buildWritesPanel(writes)),
                          const SizedBox(width: 12),
                          Expanded(child: _buildRequestPanel()),
                        ],
                      ),
                    )
                  : null,
            ),
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
            const Text(
              'Write Logs (From PLC/UI)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
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
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
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
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Registers',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Добавить регистр',
                  onPressed: _showAddRegisterDialog,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final int columns = (constraints.maxWidth / 360)
                      .floor()
                      .clamp(1, 6);
                  return GridView.builder(
                    itemCount: _ranges.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 2.3,
                    ),
                    itemBuilder: (BuildContext context, int index) {
                      final RegisterRange range = _ranges[index];
                      final bool changed = range.isChanged(
                        _bank,
                        highlightWindow,
                      );
                      _ensureRangeInputControllers(range);
                      final List<TextEditingController> valueControllers =
                          _rangeValueControllers[range.start] ??
                          <TextEditingController>[];
                      final List<FocusNode> focusNodes =
                          _rangeValueFocusNodes[range.start] ?? <FocusNode>[];
                      final List<int> currentValues =
                          _bank.readRangeRaw(
                            range.start,
                            range.storageLength,
                          ) ??
                          List<int>.filled(range.storageLength, 0);
                      return DragTarget<int>(
                        onWillAcceptWithDetails: (
                          DragTargetDetails<int> details,
                        ) {
                          return details.data != index;
                        },
                        onAcceptWithDetails: (
                          DragTargetDetails<int> details,
                        ) {
                          _reorderRanges(details.data, index);
                        },
                        builder: (
                          BuildContext context,
                          List<int?> candidateData,
                          List<dynamic> rejectedData,
                        ) {
                          final bool isDropTarget = candidateData.isNotEmpty;

                          Widget buildDragCard() => _buildRangeCard(
                            range: range,
                            index: index,
                            changed: changed,
                            valueControllers: valueControllers,
                            focusNodes: focusNodes,
                            currentValues: currentValues,
                          );

                          final Widget feedbackCard = Material(
                            color: Colors.transparent,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints.tightFor(
                                width: 320,
                                height: 140,
                              ),
                              child: Opacity(
                                opacity: 0.88,
                                child: buildDragCard(),
                              ),
                            ),
                          );

                          final Widget dragTargetCard = DecoratedBox(
                            decoration: BoxDecoration(
                              border: isDropTarget
                                  ? Border.all(
                                      color: Colors.lightBlueAccent,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: buildDragCard(),
                          );

                          final Widget cardPlaceholder = Opacity(
                            opacity: 0.35,
                            child: buildDragCard(),
                          );

                          if (_useImmediateMouseDrag) {
                            return Draggable<int>(
                              data: index,
                              feedback: feedbackCard,
                              childWhenDragging: cardPlaceholder,
                              child: dragTargetCard,
                            );
                          }

                          return LongPressDraggable<int>(
                            data: index,
                            feedback: feedbackCard,
                            childWhenDragging: cardPlaceholder,
                            child: dragTargetCard,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeCard({
    required RegisterRange range,
    required int index,
    required bool changed,
    required List<TextEditingController> valueControllers,
    required List<FocusNode> focusNodes,
    required List<int> currentValues,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Побитный редактор',
                onPressed: () => _showBitEditor(range),
                icon: const Icon(Icons.tune, size: 18),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _removeRange(index),
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                ),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: valueControllers.length,
              itemBuilder: (BuildContext context, int row) {
                final int addr = range.start + row;
                final int value =
                    row < currentValues.length ? currentValues[row] : 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 84,
                        child: Text(
                          '[$addr] $value',
                          style: const TextStyle(
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: valueControllers[row],
                          focusNode:
                              row < focusNodes.length ? focusNodes[row] : null,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Новое значение',
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: 32,
            width: double.infinity,
            child: FilledButton(
              onPressed: () => _writeRangeValue(range),
              child: const Text('Записать'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Request Logs (MBAP + Modbus Request APU)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _toggleRequestLogPause,
                icon: Icon(_requestLogPaused ? Icons.play_arrow : Icons.pause),
                label: Text(_requestLogPaused ? 'Resume' : 'Pause'),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: _requestLogView.length,
                itemBuilder: (BuildContext context, int index) {
                  final ModbusLogEntry e = _requestLogView[index];

                  return Text(
                    'fc=0x${e.functionCode.toRadixString(16).toUpperCase().padLeft(2, '0')} '
                    'addr=${e.startAddress} len=${e.length}\n'
                    'MBAP: ${e.mbapHeader}\n'
                    'ModbusReq: ${e.modbusRequest}\n'
                    'APU(bytes): ${e.requestApu}\n'
                    'Result: ${e.result}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BitEditorDialog extends StatefulWidget {
  const _BitEditorDialog({required this.range, required this.bank});

  final RegisterRange range;
  final SparseHoldingRegisterBank bank;

  @override
  State<_BitEditorDialog> createState() => _BitEditorDialogState();
}

class _BitEditorDialogState extends State<_BitEditorDialog> {
  static const Duration _syncInterval = Duration(milliseconds: 250);

  late final List<int> _values;
  final Set<int> _dirtyRows = <int>{};
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _values = _readCurrentValues();
    _syncTimer = Timer.periodic(_syncInterval, (_) => _syncFromBank());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  List<int> _readCurrentValues() {
    return List<int>.from(
      widget.bank.readRangeRaw(widget.range.start, widget.range.storageLength) ??
          List<int>.filled(widget.range.storageLength, 0),
    );
  }

  void _syncFromBank() {
    final List<int> latestValues = _readCurrentValues();
    bool hasChanges = false;

    for (int i = 0; i < _values.length; i++) {
      if (_dirtyRows.contains(i)) {
        continue;
      }
      if (_values[i] != latestValues[i]) {
        _values[i] = latestValues[i];
        hasChanges = true;
      }
    }

    if (hasChanges && mounted) {
      setState(() {});
    }
  }

  void _toggleBit(int row, int bit) {
    setState(() {
      _dirtyRows.add(row);
      _values[row] = _values[row] ^ (1 << bit);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Bits: ${widget.range.name}'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List<Widget>.generate(widget.range.storageLength, (int row) {
              final int value = _values[row];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Address ${widget.range.start + row} | value=$value | 0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: List<Widget>.generate(16, (int offset) {
                        final int bit = 15 - offset;
                        final bool enabled = ((_values[row] >> bit) & 0x1) == 1;
                        return FilterChip(
                          selected: enabled,
                          label: Text('b$bit:${enabled ? 1 : 0}'),
                          onSelected: (_) => _toggleBit(row, bit),
                        );
                      }),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(List<int>.from(_values)),
          child: const Text('Применить'),
        ),
      ],
    );
  }
}
