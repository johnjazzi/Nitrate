import StoreKit

/// CAP-9: StoreKit 2 purchase manager with 7-day free trial.
/// $5/year subscription or $10 lifetime purchase.
@MainActor
final class StoreManager: Observable {
    private let subscriptionID = "com.filmemulation.subscription.yearly"
    private let lifetimeID = "com.filmemulation.lifetime"

    private(set) var products: [Product] = []
    private(set) var isTrialActive = false
    private(set) var isPurchased = false

    private var updatesTask: Task<Void, Never>?

    // MARK: - Trial Management

    /// Check if the 7-day trial is active or the user has purchased.
    func checkStatus() async {
        // Restore purchases
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            await handleVerifiedTransaction(transaction)
        }

        // Start trial tracking if not purchased
        if !isPurchased {
            checkTrialStatus()
        }
    }

    /// Start observing transaction updates.
    func observeTransactions() {
        updatesTask = Task {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await handleVerifiedTransaction(transaction)
                await transaction.finish()
            }
        }
    }

    /// Load StoreKit products.
    func loadProducts() async {
        do {
            let ids: [String] = [subscriptionID, lifetimeID]
            products = try await Product.products(for: ids)
        } catch {
            // Product loading failure — retry can be triggered by user
        }
    }

    /// Purchase the yearly subscription.
    func purchaseSubscription() async throws {
        guard let product = products.first(where: { $0.id == subscriptionID }) else {
            throw PurchaseError.productNotFound
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return }
            isPurchased = true
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    /// Purchase lifetime unlock.
    func purchaseLifetime() async throws {
        guard let product = products.first(where: { $0.id == lifetimeID }) else {
            throw PurchaseError.productNotFound
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return }
            isPurchased = true
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func stopObserving() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    // MARK: - Private

    private func handleVerifiedTransaction(_ transaction: Transaction) async {
        isPurchased = true
        UserDefaults.standard.set(transaction.purchaseDate, forKey: "purchase_date")
    }

    private func checkTrialStatus() {
        let installDate = installDateKey
        let trialDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        isTrialActive = Date().timeIntervalSince(installDate) < trialDuration
    }

    /// First-launch tracking for trial start.
    private var installDateKey: Date {
        if let stored = UserDefaults.standard.object(forKey: "install_date") as? Date {
            return stored
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: "install_date")
        return now
    }
}

enum PurchaseError: LocalizedError {
    case productNotFound

    var errorDescription: String? {
        switch self {
        case .productNotFound: return "Product not found in App Store."
        }
    }
}