import Foundation
import StoreKit

/// Apple-compliant StoreKit 2 tip jar (mirrors the pattern proven in InputConfig).
/// Consumable one-time tips plus optional monthly auto-renewable tips. All products must
/// exist in App Store Connect exactly as written; until then the UI shows a friendly
/// unavailable state and the external GitHub Sponsors / Buy Me a Coffee links still work.
@MainActor
final class TipJarService: ObservableObject {
    static let shared = TipJarService()

    static let consumableProductIDs: [String] = [
        "com.ryleighnewman.YapToText.tip.small",
        "com.ryleighnewman.YapToText.tip.med",
        "com.ryleighnewman.YapToText.tip.large",
        "com.ryleighnewman.YapToText.tip.generous",
    ]

    static let subscriptionProductIDs: [String] = [
        "com.ryleighnewman.YapToText.tip.small.monthly",
        "com.ryleighnewman.YapToText.tip.medium.monthly",
        "com.ryleighnewman.YapToText.tip.large.monthly",
        "com.ryleighnewman.YapToText.tip.generous.monthly",
    ]

    @Published private(set) var consumableProducts: [Product] = []
    @Published private(set) var subscriptionProducts: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var totalTipsCount: Int = 0
    @Published private(set) var activeSubscription: Product?
    @Published var purchaseInProgress: String?

    private var transactionListener: Task<Void, Never>?
    private static let tipCountKey = "YapToText.tipCount"

    private init() {
        totalTipsCount = UserDefaults.standard.integer(forKey: Self.tipCountKey)
        transactionListener = listenForTransactions()
    }

    deinit { transactionListener?.cancel() }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.consumableProductIDs + Self.subscriptionProductIDs)
            consumableProducts = fetched.filter { $0.type == .consumable }.sorted { $0.price < $1.price }
            subscriptionProducts = fetched.filter { $0.type == .autoRenewable }.sorted { $0.price < $1.price }
        } catch {
            NSLog("TipJarService: product load failed: \(error.localizedDescription)")
        }
        await refreshActiveSubscription()
    }

    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        purchaseInProgress = product.id
        defer { purchaseInProgress = nil }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            incrementTipCount()
            await refreshActiveSubscription()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshActiveSubscription()
    }

    private func refreshActiveSubscription() async {
        var found: Product?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable else { continue }
            if let match = subscriptionProducts.first(where: { $0.id == transaction.productID }) { found = match; break }
        }
        activeSubscription = found
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    if transaction.productType != .autoRenewable {
                        await MainActor.run { self.incrementTipCount() }
                    }
                    await self.refreshActiveSubscription()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified: throw TipJarError.unverified
        }
    }

    private func incrementTipCount() {
        totalTipsCount += 1
        UserDefaults.standard.set(totalTipsCount, forKey: Self.tipCountKey)
    }
}

enum TipJarError: LocalizedError {
    case unverified
    var errorDescription: String? { "The App Store returned an unverified transaction. Tip was not processed." }
}
