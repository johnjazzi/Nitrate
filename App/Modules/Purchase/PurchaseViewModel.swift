import Observation
import StoreKit

/// AD-1: @Observable ViewModel for the purchase/settings screen.
@MainActor
@Observable
final class PurchaseViewModel {
    private let storeManager = StoreManager()

    // MARK: - Observable State

    var isTrialActive = false
    var isPurchased = false
    var daysRemaining: Int = 0
    var subscriptionPrice: String?
    var lifetimePrice: String?
    var purchaseError: String?

    // MARK: - Actions

    func onAppear() {
        Task {
            await loadState()
        }
        storeManager.observeTransactions()
    }

    func onDisappear() {
        storeManager.stopObserving()
    }

    func purchaseSubscription() {
        Task {
            do {
                try await storeManager.purchaseSubscription()
                await refreshState()
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    func purchaseLifetime() {
        Task {
            do {
                try await storeManager.purchaseLifetime()
                await refreshState()
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    func restorePurchases() {
        Task {
            await storeManager.checkStatus()
            await refreshState()
        }
    }

    func dismissError() {
        purchaseError = nil
    }

    // MARK: - Private

    private func loadState() async {
        await storeManager.loadProducts()
        await storeManager.checkStatus()
        await refreshState()
    }

    private func refreshState() async {
        isTrialActive = storeManager.isTrialActive
        isPurchased = storeManager.isPurchased

        let installDate = UserDefaults.standard.object(forKey: "install_date") as? Date ?? Date()
        let elapsed = Date().timeIntervalSince(installDate)
        let trialDuration: TimeInterval = 7 * 24 * 60 * 60
        daysRemaining = max(0, Int((trialDuration - elapsed) / (24 * 60 * 60)))

        subscriptionPrice = storeManager.products.first { $0.id.contains("subscription") }?.displayPrice
        lifetimePrice = storeManager.products.first { $0.id.contains("lifetime") }?.displayPrice
    }
}