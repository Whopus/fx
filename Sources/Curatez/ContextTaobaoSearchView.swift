import Foundation
import SwiftUI

struct ContextTaobaoSearchCall: Equatable {
    let endpointID: String
    let action: String
    let subject: String?
    let metadata: String?

    static func parse(_ payload: JSONValue?) -> ContextTaobaoSearchCall? {
        guard let root = taobaoObject(payload),
              let endpointID = taobaoString(root["endpoint_id"]),
              endpointID.hasPrefix("taobao.") else { return nil }
        let params = taobaoObject(root["params"]) ?? [:]
        let page = taobaoNumber(params["page"]).map { "page \(taobaoCompactNumber($0))" }

        if endpointID == "taobao.search_item_list_v1" {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Search products",
                subject: taobaoString(params["keyword"]),
                metadata: [page, taobaoPriceRange(params)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
            )
        }
        if endpointID.hasPrefix("taobao.get_shop_item_list_") {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Browse shop",
                subject: taobaoString(params["shop_id"]) ?? taobaoString(params["seller_id"]) ?? taobaoString(params["user_id"]),
                metadata: page
            )
        }
        if endpointID.hasPrefix("taobao.get_item_detail_") {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Get product details",
                subject: taobaoString(params["item_id"]),
                metadata: nil
            )
        }
        if endpointID.hasPrefix("taobao.get_item_comment_") {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Load reviews",
                subject: taobaoString(params["item_id"]),
                metadata: page
            )
        }
        if endpointID.hasPrefix("taobao.get_social_feed_") {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Search Q&A",
                subject: taobaoString(params["item_id"]),
                metadata: page
            )
        }
        if endpointID.hasPrefix("taobao.get_item_sale_") {
            return ContextTaobaoSearchCall(
                endpointID: endpointID,
                action: "Get product sales",
                subject: taobaoString(params["item_id"]),
                metadata: nil
            )
        }
        return ContextTaobaoSearchCall(endpointID: endpointID, action: "Search", subject: nil, metadata: nil)
    }
}

struct ContextTaobaoSearchResult: Equatable {
    let kind: String
    let summary: [String: JSONValue]
    let data: [String: JSONValue]

    static func parse(_ payload: JSONValue?) -> ContextTaobaoSearchResult? {
        guard let root = taobaoObject(payload) else { return nil }
        let details = taobaoObject(root["details"]) ?? root
        guard let presentation = taobaoObject(details["presentation"]),
              taobaoString(presentation["platform"]) == "taobao",
              let kind = taobaoString(presentation["kind"]),
              let data = taobaoObject(presentation["data"]) else { return nil }
        return ContextTaobaoSearchResult(
            kind: kind,
            summary: taobaoObject(presentation["summary"]) ?? [:],
            data: data
        )
    }
}

struct ContextTaobaoSearchActivityView: View {
    let call: ContextTaobaoSearchCall
    let resultPayload: JSONValue?
    let resultText: String?
    let isRunning: Bool
    let isError: Bool

    @State private var isExpanded = false

    private var result: ContextTaobaoSearchResult? {
        ContextTaobaoSearchResult.parse(resultPayload)
    }

    private var hasResult: Bool {
        isRunning || isError || result != nil || resultText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                ContextTaobaoIcon()
                    .frame(width: 15, height: 18, alignment: .leading)

                HStack(spacing: 7) {
                    Text(call.action)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                    Text("Taobao")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.58))
                    if let metadata = call.metadata {
                        Text("·  \(metadata)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.58))
                    }
                    Spacer(minLength: 8)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.secondary.opacity(0.6))
                    }
                }
            }

            if let subject = call.subject {
                Text(subject)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.leading, 25)
            }

            if hasResult {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 1)
                    .padding(.vertical, 2)
                    .padding(.leading, 25)

                if isRunning {
                    ContextTaobaoStatus(icon: nil, text: "Searching Taobao…", isError: false, showsSpinner: true)
                } else if isError {
                    ContextTaobaoStatus(
                        icon: "xmark.circle",
                        text: resultText?.nilIfEmpty ?? "Search failed",
                        isError: true,
                        showsSpinner: false
                    )
                } else if let result {
                    ContextTaobaoResultContent(result: result, isExpanded: $isExpanded)
                        .padding(.leading, 25)
                } else {
                    ContextTaobaoStatus(icon: "checkmark.circle", text: resultText?.nilIfEmpty ?? "Completed", isError: false, showsSpinner: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextTaobaoIcon: View {
    var body: some View {
        Text("淘")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Color(red: 1, green: 0.31, blue: 0), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .accessibilityLabel("Taobao")
    }
}

private struct ContextTaobaoStatus: View {
    let icon: String?
    let text: String
    let isError: Bool
    let showsSpinner: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if showsSpinner {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                }
            }
            .foregroundStyle(isError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.64))
            .frame(width: 13, height: 16)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(isError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.74))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 25)
    }
}

private struct ContextTaobaoResultContent: View {
    let result: ContextTaobaoSearchResult
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.64))
                Text(resultSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.74))
            }

            switch result.kind {
            case "product-list":
                ContextTaobaoProductList(data: result.data, isExpanded: $isExpanded)
            case "product-detail":
                ContextTaobaoProductDetail(data: result.data, isExpanded: $isExpanded)
            case "review-list":
                ContextTaobaoReviewList(data: result.data, isExpanded: $isExpanded)
            case "question-list":
                ContextTaobaoQuestionList(data: result.data, isExpanded: $isExpanded)
            default:
                ContextTaobaoFacts(data: result.data)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultSummary: String {
        let count = taobaoNumber(result.summary["count"])
        let total = taobaoNumber(result.summary["totalItems"])
        let totalText = taobaoString(result.summary["totalText"])
        let page = taobaoNumber(result.summary["page"])
        let totalPages = taobaoNumber(result.summary["totalPages"])
        var parts: [String] = []
        if let totalText { parts.append("\(totalText) results") }
        else if let total { parts.append("\(taobaoCompactNumber(total)) results") }
        else if let count { parts.append("\(taobaoCompactNumber(count)) found") }
        if let page {
            let suffix = totalPages.map { "/\(taobaoCompactNumber($0))" } ?? ""
            parts.append("page \(taobaoCompactNumber(page))\(suffix)")
        }
        return parts.nilIfEmpty ?? "Completed"
    }
}

private struct ContextTaobaoProductList: View {
    let data: [String: JSONValue]
    @Binding var isExpanded: Bool

    private var items: [[String: JSONValue]] { taobaoObjects(data["items"]) }
    private var visibleItems: ArraySlice<[String: JSONValue]> { isExpanded ? items[...] : items.prefix(5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No products found")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.68))
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                    ContextTaobaoProductRow(item: item)
                    if index < visibleItems.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }

            if items.count > 5 {
                Button(isExpanded ? "Show less" : "Show all · \(items.count) products") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .padding(.top, 7)
            }
        }
    }
}

private struct ContextTaobaoProductRow: View {
    let item: [String: JSONValue]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let imageURL = taobaoURL(item["imageURL"]) {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.06)
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let title = taobaoString(item["title"]) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let price = taobaoMoney(item["price"]) {
                        Text(price)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.88, green: 0.25, blue: 0.06))
                    }
                    if let original = taobaoMoney(item["originalPrice"]) {
                        Text(original)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary.opacity(0.48))
                            .strikethrough()
                    }
                    if let sales = taobaoObject(item["sales"]), let value = taobaoString(sales["value"]) {
                        Text(value)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary.opacity(0.62))
                    }
                }
                let shopName = taobaoObject(item["shop"]).flatMap { taobaoString($0["name"]) }
                let location = taobaoString(item["location"])
                if shopName != nil || location != nil {
                    Text([shopName, location].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary.opacity(0.56))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = taobaoURL(item["url"]) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.48))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct ContextTaobaoProductDetail: View {
    let data: [String: JSONValue]
    @Binding var isExpanded: Bool

    private var properties: [[String: JSONValue]] { taobaoObjects(data["properties"]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContextTaobaoProductRow(item: detailRow)

            let facts = detailFacts
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.62))
            }

            if !properties.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((isExpanded ? properties[...] : properties.prefix(6)).enumerated()), id: \.offset) { _, property in
                        if let name = taobaoString(property["name"]), let value = taobaoString(property["value"]) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(name).frame(width: 76, alignment: .leading)
                                Text(value).foregroundStyle(.primary.opacity(0.7)).textSelection(.enabled)
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary.opacity(0.62))
                        }
                    }
                }
                if properties.count > 6 {
                    Button(isExpanded ? "Show less" : "Show all · \(properties.count) properties") { isExpanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.62))
                }
            }
        }
    }

    private var detailRow: [String: JSONValue] {
        var row = data
        row["imageURL"] = data["mainImageURL"]
        if let price = taobaoObjects(data["prices"]).first {
            row["price"] = price["value"]
        } else if let variants = taobaoObject(data["variantSummary"]) {
            row["price"] = variants["minimumPrice"]
        }
        return row
    }

    private var detailFacts: [String] {
        var facts: [String] = []
        if let brand = taobaoString(data["brand"]) { facts.append(brand) }
        if let location = taobaoString(data["location"]) { facts.append(location) }
        if let stock = taobaoNumber(data["stock"]) { facts.append("stock \(taobaoCompactNumber(stock))") }
        if let variants = taobaoObject(data["variantSummary"]), let count = taobaoNumber(variants["count"]) {
            facts.append("\(taobaoCompactNumber(count)) variants")
        }
        return facts
    }
}

private struct ContextTaobaoReviewList: View {
    let data: [String: JSONValue]
    @Binding var isExpanded: Bool

    private var reviews: [[String: JSONValue]] {
        taobaoObjects(data["reviews"]).filter { taobaoBool($0["systemGenerated"]) != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if reviews.isEmpty {
                Text("No informative reviews")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.68))
                    .padding(.vertical, 6)
            }
            ForEach(Array((isExpanded ? reviews[...] : reviews.prefix(5)).enumerated()), id: \.offset) { index, review in
                VStack(alignment: .leading, spacing: 4) {
                    let author = taobaoString(review["author"])
                    let date = taobaoString(review["date"])
                    let score = taobaoNumber(review["score"])
                    if author != nil || date != nil || score != nil {
                        HStack(spacing: 6) {
                            if let author { Text(author) }
                            if let score { Text("\(taobaoCompactNumber(score))/5") }
                            if let date { Text(date) }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                    }
                    if let content = taobaoString(review["content"]) {
                        Text(content)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.76))
                            .lineLimit(isExpanded ? nil : 4)
                            .textSelection(.enabled)
                    }
                    if let sku = taobaoString(review["sku"]) {
                        Text(sku).font(.system(size: 10.5)).foregroundStyle(.secondary.opacity(0.52))
                    }
                }
                .padding(.vertical, 7)
                if index < min(reviews.count, isExpanded ? reviews.count : 5) - 1 { Divider().opacity(0.45) }
            }
            if reviews.count > 5 {
                Button(isExpanded ? "Show less" : "Show all · \(reviews.count) reviews") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .padding(.top, 7)
            }
        }
    }
}

private struct ContextTaobaoQuestionList: View {
    let data: [String: JSONValue]
    @Binding var isExpanded: Bool

    private var questions: [[String: JSONValue]] { taobaoObjects(data["questions"]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if questions.isEmpty {
                Text("No questions found").font(.system(size: 11.5)).foregroundStyle(.secondary.opacity(0.68)).padding(.vertical, 6)
            }
            ForEach(Array((isExpanded ? questions[...] : questions.prefix(5)).enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 5) {
                    if let title = taobaoString(question["question"]) {
                        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary.opacity(0.8))
                    }
                    ForEach(Array(taobaoObjects(question["answers"]).prefix(isExpanded ? 4 : 2).enumerated()), id: \.offset) { _, answer in
                        if let value = taobaoString(answer["answer"]) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.31, blue: 0))
                                Text(value).font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.7)).lineLimit(isExpanded ? nil : 3)
                            }
                        }
                    }
                }
                .padding(.vertical, 7)
                if index < min(questions.count, isExpanded ? questions.count : 5) - 1 { Divider().opacity(0.45) }
            }
            if questions.count > 5 {
                Button(isExpanded ? "Show less" : "Show all · \(questions.count) questions") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .padding(.top, 7)
            }
        }
    }
}

private struct ContextTaobaoFacts: View {
    let data: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(data.keys.sorted(), id: \.self) { key in
                if let value = taobaoScalar(data[key]) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(key).frame(width: 78, alignment: .leading)
                        Text(value).foregroundStyle(.primary.opacity(0.72)).textSelection(.enabled)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.62))
                }
            }
        }
    }
}

private func taobaoObject(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object) = value else { return nil }
    return object
}

private func taobaoObjects(_ value: JSONValue?) -> [[String: JSONValue]] {
    guard case .array(let values) = value else { return [] }
    return values.compactMap(taobaoObject)
}

private func taobaoString(_ value: JSONValue?) -> String? {
    switch value {
    case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    case .number(let number): return taobaoCompactNumber(number)
    default: return nil
    }
}

private func taobaoNumber(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number): return number
    case .string(let text): return Double(text.replacingOccurrences(of: ",", with: ""))
    default: return nil
    }
}

private func taobaoBool(_ value: JSONValue?) -> Bool? {
    guard case .bool(let value) = value else { return nil }
    return value
}

private func taobaoURL(_ value: JSONValue?) -> URL? {
    taobaoString(value).flatMap(URL.init(string:))
}

private func taobaoMoney(_ value: JSONValue?) -> String? {
    guard let number = taobaoNumber(value) else { return nil }
    return "¥\(taobaoCompactNumber(number))"
}

private func taobaoCompactNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
}

private func taobaoPriceRange(_ params: [String: JSONValue]) -> String? {
    let minimum = taobaoString(params["start_price"])
    let maximum = taobaoString(params["end_price"])
    guard minimum != nil || maximum != nil else { return nil }
    return "¥\(minimum ?? "0")–\(maximum.map { "¥\($0)" } ?? "any")"
}

private func taobaoScalar(_ value: JSONValue?) -> String? {
    switch value {
    case .string(let text): return text.nilIfEmpty
    case .number(let number): return taobaoCompactNumber(number)
    case .bool(let value): return value ? "Yes" : "No"
    default: return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Array where Element == String {
    var nilIfEmpty: String? { isEmpty ? nil : joined(separator: " · ") }
}
