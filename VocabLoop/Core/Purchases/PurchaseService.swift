import Foundation
import Observation
import OSLog
import StoreKit

/// Buys and restores VocabLoop Plus with StoreKit 2.
///
/// No server: StoreKit 2 transactions arrive signed by the App Store and verified on device,
/// which is all a one-off unlock needs.
@MainActor
@Observable
public final class PurchaseService {
    public enum State: Equatable {
        case idle
        case purchasing
        /// Ask to Buy, or a payment that needs the bank's approval. It completes later
        /// through `Transaction.updates`.
        case pending
    }

    /// `nil` until the App Store answers — or for good if the product is not live yet (no
    /// Paid Applications agreement, or the purchase not yet created in App Store Connect).
    public private(set) var product: Product?
    public private(set) var state: State = .idle
    public private(set) var lastError: String?
    /// `true` once a product lookup has finished, whatever it found.
    public private(set) var hasLoaded = false

    public let entitlements: Entitlements
    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "purchases")

    public init(entitlements: Entitlements) {
        self.entitlements = entitlements
        // Purchases finished outside the paywall: Ask to Buy approvals, a purchase made on
        // another device, a refund. Started at launch so none of them is missed.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    public var displayPrice: String? {
        #if DEBUG
        // App Store screenshots show the China price. The simulator may have no product to load,
        // or load the US sandbox storefront's price; either way the screenshot uses ours.
        // Debug builds only.
        if AppStoreScreenshots.isActive { return AppStoreScreenshots.displayPrice }
        #endif
        return product?.displayPrice
    }

    /// Load the product and re-check what this Apple ID owns. Called at launch.
    public func load() async {
        do {
            product = try await Product.products(for: [PlusCatalog.lifetimeProductID]).first
            if product == nil {
                logger.info("Plus product not returned by the App Store")
            }
        } catch {
            logger.error("Product lookup failed: \(error.localizedDescription, privacy: .public)")
        }
        hasLoaded = true
        await refreshEntitlement()
    }

    public func purchase() async {
        guard let product else {
            lastError = "暂时连不上 App Store，请稍后再试。"
            return
        }
        lastError = nil
        state = .purchasing
        defer { if state == .purchasing { state = .idle } }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .pending:
                state = .pending
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Restore purchases". Required by App Review for any non-consumable.
    public func restore() async {
        lastError = nil
        state = .purchasing
        defer { state = .idle }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlement()
        if !entitlements.isPlus, lastError == nil {
            lastError = "这个 Apple ID 没有购买过麻薯 Plus 的记录。"
        }
    }

    public func clearError() { lastError = nil }

    private func refreshEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == PlusCatalog.lifetimeProductID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        entitlements.setPlus(owned)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            // An unverifiable transaction is never honoured — that is the whole point of the
            // signature — but it is not the user's fault either, so nothing alarming is shown.
            logger.error("Ignored an unverified transaction")
            return
        }
        if transaction.productID == PlusCatalog.lifetimeProductID {
            entitlements.setPlus(transaction.revocationDate == nil)
            if state == .pending { state = .idle }
        }
        await transaction.finish()
    }
}
