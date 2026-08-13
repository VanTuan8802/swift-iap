# SwiftIAP — Guide & Prompt để apply vào app mới

Tài liệu này gồm 2 phần:
- **Phần A** — Các bước tự làm (checklist ngắn).
- **Phần B** — Prompt copy-paste để đưa cho AI agent (Claude Code / Cursor…) tự wire vào project.

---

## Phần A — Apply thủ công (7 bước)

### 1. Thêm package
Xcode ▸ File ▸ Add Package Dependencies… ▸ trỏ tới repo/thư mục `swift-iap`.
Hoặc trong `Package.swift`:
```swift
.package(path: "../swift-iap")
// target deps:
.product(name: "SwiftIAP", package: "swift-iap")
```

### 2. Bật capability
Xcode ▸ target ▸ Signing & Capabilities ▸ **+ In-App Purchase**.

### 3. Khai báo product của bạn
```swift
import SwiftIAP

enum AppProduct: String, InAppProduct, CaseIterable {
    case weekly = "com.myapp.weekly"      // ⚠️ đổi thành Product ID thật trên App Store Connect
    case yearly = "com.myapp.yearly"
    var id: String { rawValue }
}
```

### 4. Configure MỘT lần, sớm nhất khi launch
```swift
IAPConfiguration.shared.configure(
    premiumProductIds: AppProduct.allCases.map(\.id),
    // subscriptionProductIds mặc định = premium list

    // (tùy chọn) nối remote config để bật/tắt IAP khi review App Store:
    remoteConfig: ClosureIAPRemoteConfig(
        enableIAP: { true }               // đổi thành đọc Firebase Remote Config
    ),

    // (tùy chọn) nối ads SDK — bỏ qua nếu app không có ads:
    // ads: ClosureIAPAdsBridging(setExcludeScreen: {...}, setShouldShowAds: {...}),

    // (tùy chọn) local notification báo hết free trial:
    // trialNotifications: ClosureTrialNotificationScheduler(schedule: {...}, remove: {...}),

    localize: { NSLocalizedString($0, comment: "") },
    persistenceKeyPrefix: "com.myapp.iap",  // namespace tránh trùng nếu có 2 app
    enableLogging: false
)
```

### 5. Bootstrap ở App entry point
```swift
@main
struct MyApp: App {
    @StateObject private var store: StoreContext

    init() {
        IAPConfiguration.shared.configure(premiumProductIds: AppProduct.allCases.map(\.id))
        _store = StateObject(wrappedValue: SwiftIAP.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)   // inject cho toàn app
        }
    }
}
```

### 6. Dùng ở các màn hình
```swift
// Check quyền (sync — single source of truth)
if IAPHelper.shared.hasPremiumAccess { /* mở khóa */ }
if IAPHelper.shared.shouldGatePremium { showPaywall = true }

// Mua / khôi phục
IAPManager.shared.purchase(product)
IAPManager.shared.restorePurchases()
// observe: IAPManager.shared.isLoading / .errorMessage / .showingPurchaseAlert

// Gate 1 view (blur + overlay UI của BẠN)
myFeature.premiumGated {
    MyLockedOverlay(title: "Feature X")   // tự thiết kế, package không kèm asset
}

// Free tier (nếu dùng)
guard FreeMeasureManager.shared.canMeasureFree() else { showPaywall = true; return }
doFeature()
FreeMeasureManager.shared.recordFreeMeasure()
```

### 7. Thêm localization keys
Copy các key ở mục "Localization keys" trong `README.md` vào `Localizable.strings`.
Key thiếu sẽ fallback về chính tên key (không crash).

### Checklist test (Sandbox)
- [ ] Mua từng product → `IAPHelper.shared.isPremium == true`
- [ ] Restore hoạt động
- [ ] Force-kill app → mở lại → premium vẫn đúng (đọc từ cache ngay)
- [ ] `getEnableIAP() == false` → `hasPremiumAccess == true` (cho reviewer)
- [ ] `premiumGated { }` blur/unblur đúng trạng thái

---

## Phần B — Prompt cho AI agent

> Copy nguyên khối dưới đây, dán vào Claude Code / Cursor khi đang mở project app cần tích hợp.
> Nhớ sửa 3 chỗ `⟨...⟩` trước khi gửi.

```
Tôi có một Swift package tên SwiftIAP (StoreKit 2 thuần, không phụ thuộc thư viện ngoài).
Hãy tích hợp nó vào project iOS hiện tại của tôi.

Đường dẫn package: ⟨/path/to/swift-iap⟩
Product IDs (App Store Connect): ⟨com.myapp.weekly, com.myapp.yearly⟩
App có ads không: ⟨có / không⟩

API của package:
- IAPConfiguration.shared.configure(premiumProductIds:subscriptionProductIds:remoteConfig:ads:
  trialNotifications:localize:persistenceKeyPrefix:enableLogging:) — gọi 1 lần lúc launch.
- SwiftIAP.bootstrap() -> StoreContext — wire StoreContext→IAPHelper→IAPManager, trả về store để inject.
- IAPHelper.shared.hasPremiumAccess / .shouldGatePremium / .isPremium — check quyền (sync).
- IAPManager.shared.purchase(_:) / .restorePurchases() ; observe .isLoading/.errorMessage/.showingPurchaseAlert.
- View.premiumGated { <overlay UI của tôi> } — blur + overlay khi chưa premium.
- FreeMeasureManager.shared.canMeasureFree()/recordFreeMeasure()/getRemainingFreeMeasures() — free tier (tùy chọn).
- Protocol để inject: IAPRemoteConfigProviding, IAPAdsBridging, IAPTrialNotificationScheduling
  (đều có default no-op + biến thể Closure...).

Yêu cầu:
1. Thêm SwiftIAP làm dependency (SPM), bật capability In-App Purchase.
2. Tạo enum AppProduct: InAppProduct với các Product ID ở trên.
3. Gọi IAPConfiguration.configure(...) + SwiftIAP.bootstrap() trong App entry point,
   inject StoreContext qua .environmentObject.
   - Nếu app có ads: nối IAPAdsBridging vào ads manager hiện có của tôi.
   - Nối remote config enableIAP vào ⟨Firebase Remote Config / hằng true⟩.
4. Ở màn hình cần khóa, thay logic check premium hiện tại (nếu có) bằng IAPHelper.shared.hasPremiumAccess,
   và dùng .premiumGated { } cho phần UI premium.
5. KHÔNG tự viết lại logic StoreKit — chỉ gọi API của package.
6. Thêm các localization key mà package dùng vào Localizable.strings (fallback về key nếu thiếu).
7. Build project và báo lại các chỗ tôi cần điền thủ công (Product ID thật, asset overlay, string dịch).

Trước khi sửa, đọc README.md và APPLY_GUIDE.md trong thư mục package để nắm đúng API.
```

---

*Xem thêm `README.md` để biết chi tiết từng type và bảng "đã đổi gì so với code gốc".*
