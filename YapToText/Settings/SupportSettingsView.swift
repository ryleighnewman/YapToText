import SwiftUI
import StoreKit
import AppKit

/// The Support window - a faithful port of InputConfig's TipJarView so the two apps feel like
/// siblings: pink heart header, the pink "completely optional" callout, a recurring toggle with
/// a live explainer, tier-icon product rows with monospaced prices, subscription disclosure with
/// legal links, and the tipped-count footer. Tips go entirely through StoreKit - NO external
/// payment links (sponsor / buy-me-a-coffee), which App Store guideline 3.1.1 forbids.
struct SupportSettingsView: View {
    @StateObject private var service = TipJarService.shared
    @State private var showingThanks = false
    @State private var recurring = false
    @State private var isRestoring = false

    private static let manageSubscriptionsURL =
        URL(string: "macappstore://apps.apple.com/account/subscriptions")!

    var body: some View {
        VStack(spacing: 16) {
            header

            recurringToggle

            if service.isLoading {
                ProgressView("Loading tip options...")
                    .padding(.vertical, 40)
            } else if displayedProducts.isEmpty {
                emptyState
            } else {
                productList
            }

            if recurring {
                subscriptionDisclosure
            }

            footer
        }
        .frame(width: 480)
        .padding(20)
        .task { await service.loadProducts() }
        .alert("Thank you!", isPresented: $showingThanks) {
            Button("You're welcome", role: .cancel) {}
        } message: {
            Text("Your support means a lot. YapToText will keep getting better because of it.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 36))
                .iconTint(.pink)
            Text("Support YapToText")
                .font(.title2.weight(.semibold))
            Text("YapToText is free forever. If it makes your day easier, a tip helps fund continued development.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.pink.opacity(0.7))
                    .font(.caption2)
                Text("Tips are completely optional. YapToText is free with no locked features. Tips simply support continued development and future updates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.pink.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Recurring Toggle

    private var recurringToggle: some View {
        // The switch is PINNED to the trailing edge: the explainer text changes with the toggle
        // state, and having the switch trail the label made it shift as the caption changed.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Make this recurring monthly")
                    .font(.body)
                Text(recurring
                     ? "Tips charge automatically each month until cancelled."
                     : "Switch on to support monthly instead of one time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Make this recurring monthly", isOn: $recurring)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: - Product List

    private var displayedProducts: [Product] {
        recurring ? service.subscriptionProducts : service.consumableProducts
    }

    private var productList: some View {
        VStack(spacing: 10) {
            ForEach(displayedProducts, id: \.id) { product in
                productRow(product)
            }
        }
    }

    @ViewBuilder
    private func productRow(_ product: Product) -> some View {
        Button {
            Task { await tip(product) }
        } label: {
            HStack(spacing: 12) {
                tierIcon(for: product.id)
                    .font(.title3)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if service.purchaseInProgress == product.id {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 90, alignment: .trailing)
                } else {
                    Text(priceLabel(for: product))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .innerWell(radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(service.purchaseInProgress != nil)
    }

    private func priceLabel(for product: Product) -> String {
        if product.type == .autoRenewable {
            return "\(product.displayPrice)/mo"
        }
        return product.displayPrice
    }

    @ViewBuilder
    private func tierIcon(for productID: String) -> some View {
        if productID.contains(".small") {
            Image(systemName: "cup.and.saucer.fill")
                .iconTint(.brown)
        } else if productID.contains(".med") {
            // The consumable medium tier's ID is ".med" (not ".medium"), so the match must be
            // ".med" or the medium tip falls through to the gift icon and looks identical to the
            // generous tip - the exact duplicate-icon bug InputConfig had. ".med" also matches the
            // subscription's ".medium.monthly".
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .iconTint(.orange)
        } else if productID.contains(".large") {
            Image(systemName: "fork.knife")
                .iconTint(.purple)   // sibling canon (InputConfig): brown / orange / purple / pink
        } else {
            Image(systemName: "gift.fill")
                .iconTint(.pink)
        }
    }

    // MARK: - Subscription Disclosure

    private var subscriptionDisclosure: some View {
        // Terms/Privacy links live ONCE, in the footer below - repeating them here doubled the
        // links whenever the recurring toggle was on.
        Text("Subscription auto-renews monthly at the listed price. Cancel anytime in your App Store account. Payment is charged to your Apple ID at confirmation of purchase.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legalLinks: some View {
        HStack(spacing: 14) {
            Link("Terms of Use (EULA)", destination: SupportLinks.termsOfUse)
            Link("Privacy Policy", destination: SupportLinks.privacy)
        }
        .font(.caption2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if service.totalTipsCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "hands.sparkles.fill")
                        .iconTint(.yellow)
                    Text("You've tipped \(service.totalTipsCount) time\(service.totalTipsCount == 1 ? "" : "s"). Thank you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack {
                    Text("Payments are processed by Apple.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            HStack {
                legalLinks
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    Task { await restore() }
                } label: {
                    if isRestoring {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .buttonStyle(.solidSecondary)
                .controlSize(.small)
                .disabled(isRestoring)

                if service.activeSubscription != nil {
                    Button("Manage Subscription") {
                        NSWorkspace.shared.open(Self.manageSubscriptionsURL)
                    }
                    .buttonStyle(.solidSecondary)
                    .controlSize(.small)
                }

                Spacer()

                Button("Close") {
                    SupportWindowController.shared.close()
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Tips are temporarily unavailable")
                .font(.subheadline)
            Text("In-app tips activate once YapToText is on the App Store. Until then, the links below work great.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await service.loadProducts() }
            }
            .buttonStyle(.solidSecondary)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Purchase

    private func tip(_ product: Product) async {
        do {
            let succeeded = try await service.purchase(product)
            if succeeded { showingThanks = true }
        } catch {
            await service.loadProducts()
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        await service.restorePurchases()
    }
}
