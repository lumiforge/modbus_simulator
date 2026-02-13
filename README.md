# modbus_simulator

Industrial-grade Modbus TCP device simulator built with Flutter.

## Purpose

`modbus_simulator` emulates a deterministic Modbus TCP device for PLC, HMI and integration testing.
Designed to replace physical hardware during development and CI validation.


---

## Target Use Cases

* PLC integration testing
* HMI development without hardware
* Communication debugging (Wireshark validation)
* Automated system tests

---

## Run

```bash
flutter pub get
flutter run -d windows
```

Default:

```
TCP Port: 502 (configurable)
```

---

## Vision

Evolve into a lightweight digital twin framework for industrial device simulation.

---

