import SwiftUI

/// 网关自己写下的最近一次真实回执。原因只照它说：
/// 服务方原话摆出来，类别（钥匙被拒 / 额度用尽 / 模型不存在 / 被网关拦下…）由 `HubLineReceipt` 统一判，
/// 界面不另外猜一句「连接失败」。
///
/// 整块从 `HubPages.swift` 的 `HubRouteLedgerSection` 搬到这里：判断在 `HubLineReceipt` 一处、
/// 显示在这一个视图里一处，两边都不再各写一份。搬动只改位置，文案一个标点都没动。
struct HubReceiptView: View {
    var providerID: String

    var body: some View {
        if let receipt = HubReceiptLedger.shared.receipt(for: providerID) {
            VStack(alignment: .leading, spacing: 1) {
                Text(receipt.receiptLine)
                    .font(.system(size: 11))
                    .foregroundStyle(receipt.excludesFromAutoPick ? HubInk.red : HubInk.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(receipt.rawText)
                if !receipt.providerMessage.isEmpty {
                    Text("\(receipt.messageAttribution)：\(Self.clip(receipt.providerMessage))")
                        .font(.system(size: 11)).foregroundStyle(HubInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
                if let basis = receipt.evidenceNote {
                    Text(basis)
                        .font(.system(size: 11)).foregroundStyle(HubInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Text(receipt.exclusionNote)
                    .font(.system(size: 11))
                    .foregroundStyle(receipt.excludesFromAutoPick ? HubInk.orange : HubInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 原话整条摆出来，但给个上限：有的服务方会甩一整页 JSON，不截断就会把卡片撑散。
    /// 截断处留一个省略号，悬停里仍是完整原文（`receiptLine` 上的 `.help`）。
    private static func clip(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
