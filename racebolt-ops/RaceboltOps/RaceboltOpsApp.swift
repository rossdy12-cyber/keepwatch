import SwiftUI

@main
struct RaceboltOpsApp: App {
    var body: some Scene {
        WindowGroup {
            RaceboltOpsRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RBProduct: Identifiable {
    let id: Int
    let name: String
    let sku: String
    let priceHtml: String
    let isInStock: Bool
    let permalink: String
    let imageURL: String
}

@MainActor
final class RaceboltViewModel: ObservableObject {
    @Published var searchQuery: String = "Titanium"
    @Published var products: [RBProduct] = []
    @Published var isLoading: Bool = false
    @Published var auditOutput: String = "Tap an audit or sync action below to inspect live Racebolt UK catalog state."

    func searchCatalog(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Titanium"
        guard let url = URL(string: "https://raceboltuk.com/wp-json/wc/store/v1/products?search=\(encoded)&per_page=25") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var items: [RBProduct] = []
            for p in arr {
                let id = (p["id"] as? Int) ?? Int.random(in: 1...999999)
                let name = ((p["name"] as? String) ?? "Product").replacingOccurrences(of: "&#8211;", with: "-")
                let sku = (p["sku"] as? String) ?? "N/A"
                let inStock = (p["is_in_stock"] as? Bool) ?? true
                let link = (p["permalink"] as? String) ?? "https://raceboltuk.com"
                var priceStr = ""
                if let prices = p["prices"] as? [String: Any],
                   let rawPrice = prices["price"] as? String {
                    let sym = (prices["currency_symbol"] as? String) ?? "£"
                    if let pence = Double(rawPrice) {
                        priceStr = String(format: "%@%.2f", sym, pence / 100.0)
                    }
                }
                var imgURL = ""
                if let imgs = p["images"] as? [[String: Any]], let first = imgs.first, let src = first["src"] as? String {
                    imgURL = src
                }
                items.append(RBProduct(id: id, name: name, sku: sku, priceHtml: priceStr, isInStock: inStock, permalink: link, imageURL: imgURL))
            }
            products = items
        } catch {}
    }

    func runRemoteAudit(_ scriptName: String) async {
        auditOutput = "Running \(scriptName) on Windows Antigravity workstation..."
        guard let url = URL(string: "http://100.102.4.54:9090/api/antigravity/exec") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cmd = "python \"C:\\Users\\Ross_Dymond\\.gemini\\antigravity\\scratch\\\(scriptName)\""
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": cmd, "timeout": 25])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let out = json["output"] as? String {
            auditOutput = out
        } else {
            auditOutput = "Could not reach Windows workstation (100.102.4.54:9090)."
        }
    }
}

struct RaceboltOpsRootView: View {
    @StateObject private var vm = RaceboltViewModel()
    let quickCategories = ["Titanium", "Aluminium", "Stainless", "Ducati", "BMW", "M6", "Flanged"]

    var body: some View {
        NavigationStack {
            TabView {
                VStack(spacing: 8) {
                    HStack {
                        TextField("Search SKU or Fastener...", text: $vm.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await vm.searchCatalog(vm.searchQuery) } }
                        Button("Search") {
                            Task { await vm.searchCatalog(vm.searchQuery) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickCategories, id: \.self) { cat in
                                Button(cat) {
                                    vm.searchQuery = cat
                                    Task { await vm.searchCatalog(cat) }
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if vm.isLoading {
                        Spacer()
                        ProgressView("Searching Racebolt UK...")
                        Spacer()
                    } else {
                        List(vm.products) { item in
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: item.imageURL)) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.subheadline.bold())
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text("SKU: \(item.sku)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        if !item.priceHtml.isEmpty {
                                            Text(item.priceHtml)
                                                .font(.caption.bold())
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                Spacer()
                                Text(item.isInStock ? "IN STOCK" : "OOS")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(item.isInStock ? Color.green.opacity(0.2) : Color.red.opacity(0.2)))
                                    .foregroundStyle(item.isInStock ? .green : .red)
                            }
                        }
                    }
                }
                .tabItem { Label("Live Catalog", systemImage: "magnifyingglass.circle.fill") }

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Button("Audit Ti Stock") {
                            Task { await vm.runRemoteAudit("audit_ti_stock.py") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button("Audit Alum Cats") {
                            Task { await vm.runRemoteAudit("check_alum_cats.py") }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    .padding(.top)

                    ScrollView {
                        Text(vm.auditOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                    .padding()
                }
                .tabItem { Label("Stock Audits", systemImage: "checkmark.shield.fill") }
            }
            .navigationTitle("Racebolt UK Ops")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await vm.searchCatalog(vm.searchQuery)
            }
        }
    }
}
