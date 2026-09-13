// barcontrol-power-helper — privileged adapter control for Bar Control.
//
// The panel's "优先放电" policy disconnects the charger so the external
// device gets the power. Firmware removed the old unprivileged charging
// keys, so this small CLI is the only writer; install it as root with a
// matching sudoers entry (see install-power-helper.command) and the app
// calls it through `sudo -n`.
//
// Commands:
//   status                      print CHIE state as JSON
//   probe                       write the current value back (no state change)
//                               to prove the write path is permitted
//   discharge on|off            disconnect / reconnect the charger
import Foundation
import PowerTelemetrySupport

private func emitCompactError(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func emitJSON(ok: Bool, raw: UInt8?, note: String) {
    let rawText = raw.map { String($0) } ?? "null"
    let cut = raw.map { $0 != 0 } ?? false
    print("{\"ok\":\(ok),\"chie\":\(rawText),\"cut\":\(cut),\"note\":\"\(note)\"}")
}

private func readAdapter() -> (ok: Bool, raw: UInt8) {
    var raw: UInt8 = 0
    let ok = bcpt_adapter_control_read(&raw) == 1
    return (ok, raw)
}

private let usage = "用法: barcontrol-power-helper <status|probe|discharge on|discharge off>"

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    emitCompactError(usage, code: 2)
}

switch command {
case "status":
    let (ok, raw) = readAdapter()
    if ok {
        emitJSON(ok: true, raw: raw, note: raw == 0 ? "充电器已连接" : "充电器已断开")
        exit(0)
    }
    emitJSON(ok: false, raw: nil, note: "CHIE 键不可读")
    exit(3)

case "probe":
    guard geteuid() == 0 else { emitCompactError("probe 需要 root", code: 4) }
    let (readOK, current) = readAdapter()
    guard readOK else { emitJSON(ok: false, raw: nil, note: "CHIE 键不可读"); exit(3) }
    let wrote = bcpt_adapter_control_set(current) == 1
    let (_, verify) = readAdapter()
    emitJSON(
        ok: wrote && verify == current,
        raw: verify,
        note: wrote ? "SMC 写入路径可用" : "SMC 拒绝写入（固件已门控）"
    )
    exit(wrote ? 0 : 5)

case "discharge":
    guard arguments.count >= 2, arguments[1] == "on" || arguments[1] == "off" else {
        emitCompactError(usage, code: 2)
    }
    guard geteuid() == 0 else { emitCompactError("discharge 需要 root", code: 4) }
    let target: UInt8 = arguments[1] == "on" ? 0x08 : 0x00
    let wrote = bcpt_adapter_control_set(target) == 1
    let (_, verify) = readAdapter()
    emitJSON(
        ok: wrote && verify == target,
        raw: verify,
        note: arguments[1] == "on" ? "已断开充电器" : "已恢复充电器"
    )
    exit(wrote && verify == target ? 0 : 5)

default:
    emitCompactError(usage, code: 2)
}
