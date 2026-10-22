# ✨ Vanity Tracker

[![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-brightgreen)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Download APK](https://img.shields.io/badge/Direct%20Download-Android%20APK-E06D83?style=flat&logo=android&logoColor=white)](https://github.com/TNRUOK/vanity_tracker/raw/main/vanity-tracker.apk)

> ### 📲 Quick Install: Ready-to-Run Android APK
> You can download and install the app directly on your Android phone without building from source:  
> 🔗 [**Download vanity-tracker.apk (Direct Download)**](https://github.com/TNRUOK/vanity_tracker/raw/main/vanity-tracker.apk)
> 
> *To install: Download the `.apk` on your Android device, tap the file in Downloads, and choose **Install** (allow "Install unknown apps" if prompted).*

---


## 🌟 Key Features

### 🔍 1. Smart Barcode Scanner & Multi-Tier Intelligence
- **Live Camera Scanner**: High-speed UPC/EAN barcode scanning powered by `mobile_scanner` with flash/torch toggle.
- **Multi-Database Fallback**: Queries an embedded offline beauty intelligence catalog first, then cascades to **Open Beauty Facts v2/v0**, **Open Products Facts**, and **UPCItemDB**.
- **Auto-Populated Details**: Automatically infers brand, product name, volume/size, packaging format, skin claims, known allergens, and recommended PAO months.

### ⏳ 2. PAO Expiry Engine & Lifecycle Tracking
- **Formula-Aware Shelf Life**: Pre-configured standard cosmetic PAO lifetimes (e.g., Mascara: 3–6 months, Sunscreen: 12 months, Powders: 24 months).
- **Exact Date Calculation**: Dynamically computes exact expiration dates from the moment you tap **Mark as Opened**.
- **Color-Coded Status Badges**:
  - 🟢 **Active / Fresh** (> 30 days remaining)
  - 🟡 **Expiring Soon** (1 – 30 days remaining)
  - 🔴 **Expired** (Past safe use date)
  - ⚪ **Unopened** (Sealed backup)
  - 🟣 **Finished** (Archived)

### ⚠️ 3. Duplicate Ingestion Protection
- When scanning or manually adding a new product, the app checks your current active shelf.
- Triggers a **Duplicate Alert Dialog** if the product or barcode already exists in your collection, preventing impulsive repeat purchases.

### 🔔 4. Local Push Notifications
- Integrated with `flutter_local_notifications` and `timezone`.
- Schedules automated background reminders before products spoil (30 days before, 7 days before, and day of expiration) with zero external server requirement.

### ♻️ 5. Empties Archive & Repurchase Journal
- Log completed products to your **Empties** shelf with finished dates.
- Keep track of your satisfaction with the **Repurchase Rating** (*Would repurchase: Yes / No / Maybe*) and personal review notes.
- Computes your aggregate **Repurchase Rate %**.

### 📊 6. Budget & Cost-Per-Day Analytics
- **Investment Overview**: Real-time calculation of total investment, active shelf value, and emptied value.
- **Cost-Per-Day Formula**:
  $$\text{Cost/Day} = \frac{\text{Purchase Price}}{\max(1, \text{Days Used})}$$
- **Visual Category Breakdown**: Interactive donut chart powered by `fl_chart` showing spending distribution across Serums, Creams, Cleansers, Makeup, Sunscreens, and more.

### ☁️ 7. Offline-First & Firebase Sync
- Fully functional in offline/guest mode right out of the box using local persistent caching.
- Seamlessly syncs to Google Cloud Firestore and Firebase Authentication when connected.

### 🧾 8. On-Device Receipt Scanning & Purchase Confirmation
- **On-Device OCR**: Reads paper receipts and e-receipt screenshots directly on-device using ML Kit without uploading images to cloud APIs.
- **Conservative Receipt Extraction**: Extracts merchant name, purchase date (with ambiguity detection and 1-tap toggling), currency symbol, subtotal, tax, discount, total, and line items.
- **Price Protection & Safe Confirmation**: Draft purchases remain separate until reviewed and confirmed. When matching a receipt line to existing inventory, shelf item prices are preserved by default unless the user explicitly confirms the change.
- **Spending Source of Truth**: Unified spending calculations (`calculateUnifiedSpending`) ensure purchases are counted only once (inventory items linked to receipt lines are not double-counted). Receipts in foreign currencies are kept separate from domestic totals.

### 💖 9. Wishlist Management & Cross-Shelf Duplicate Detection
- Track desired beauty products with categories, notes, and target purchase prices.
- **Cross-Shelf Duplicate Detection**: Automatically alerts you if a wishlisted item is already owned on your active shelf or shared by a household member (matching exact barcodes or normalized brand/name).
- **Move to Vanity Shelf**: 1-tap conversion turns wishlisted items into active vanity items with prefilled catalog details and removes them from your wishlist.

### 👥 10. Secure Household Sharing & Duplicate Detection
- Invite household members via email with expiring invitations.
- Personal items remain private by default; sharing is explicit per item and fully reversible.
- Departure safety: leaving a household revokes access and unshares all items.

### 📦 11. JSON Inventory Backup & Restore (Schema V2)
- Export complete inventory, wishlist, and verified receipts to a standardized Schema V2 JSON file.
- Full backward compatibility with Schema V1 backups.
- Safe-merge logic and target user reassignment protect against data loss.

---

## 📱 App Architecture

```
lib/
├── main.dart                       # App initialization (Firebase, notifications, AuthGate)
├── theme/
│   └── app_theme.dart              # Aesthetic luxury palette (Rose, Warm Cream, Sage, Gold)
├── models/
│   ├── category_model.dart         # Standard cosmetic categories & default PAO
│   ├── product_model.dart          # Master product specs (ingredients, claims, barcode)
│   ├── vanity_item_model.dart      # User shelf item (opened date, expiry, price, status)
│   ├── user_model.dart             # User profile data
│   └── notification_model.dart     # Expiry reminder payload
├── services/
│   ├── auth_service.dart           # Authentication service (Firebase + guest fallback)
│   ├── database_service.dart       # Firestore CRUD with local SharedPreferences cache
│   ├── notification_service.dart   # Scheduled local notifications (30d, 7d, 0d)
│   └── product_lookup_service.dart # Multi-tier barcode lookup & beauty catalog
├── providers/
│   ├── auth_provider.dart          # Auth state management
│   └── vanity_provider.dart        # Shelf management, filtering, search, duplicate checks
├── widgets/
│   ├── vanity_item_card.dart       # Product item card with progress bar & urgency badge
│   ├── countdown_badge.dart        # Expiry countdown pill
│   ├── category_chip.dart          # Category filter selector
│   ├── duplicate_alert_dialog.dart # In-shelf duplicate warning dialog
│   └── repurchase_dialog.dart      # Empties rating & repurchase logger
└── screens/
    ├── auth/                       # Login & Sign-up screens
    ├── main_navigation_scaffold.dart # Navigation bar
    ├── dashboard/                  # Vanity Shelf grid/list with filters & search
    ├── product/                    # Add Product (Scanner + Manual), Edit, & Details
    ├── history/                    # Empties screen & Repurchase journal
    └── stats/                      # Budget & Cost-Per-Day analytics
```

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (`>= 3.10.7`)
- [Dart SDK](https://dart.dev/get-dart) (`>= 3.0.0`)
- Android Studio / VS Code with Flutter extension
- Android SDK (API 21+) or iOS (iOS 12.0+)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/TNRUOK/vanity_tracker.git
   cd vanity_tracker
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **(Optional) Configure Firebase:**
   - To enable cloud sync, create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com/).
   - Add your `google-services.json` to `android/app/`.
   - Add your `GoogleService-Info.plist` to `ios/Runner/`.
   *Note: If no Firebase config is present, the app gracefully defaults to offline local mode.*

4. **Run the invitation email backend (optional, for email delivery):**
   ```bash
   cd server
   npm install
   # Copy template to .env and configure GMAIL_USER and GMAIL_APP_PASSWORD
   cp .env.example .env
   npm start
   ```

5. **Run the application:**
   - **Chrome / Web:**
     ```bash
     flutter run -d chrome
     ```
   - **Android Emulator:**
     ```bash
     flutter run -d emulator-id
     ```
     *(Default invitation server address http://10.0.2.2:8787 connects automatically to laptop localhost:8787)*
   - **Physical Android Phone:**
     1. Set `HOST=0.0.0.0` in `server/.env` (on trusted private Wi-Fi).
     2. Start the email server: `cd server && npm start`.
     3. Run the app with your laptop's local LAN IP:
        ```bash
        flutter run -d <device-id> --dart-define=INVITE_API_BASE_URL=http://<YOUR_LAPTOP_LAN_IP>:8787
        ```

---

## 🧪 Testing & Code Quality

The codebase enforces strict linting and includes automated unit, state, and widget tests:

```bash
# Run static analysis
flutter analyze

# Run unit and widget test suite
flutter test
```

### Test Coverage Highlights:
- ✅ **PAO Calculation Engine**: Tests covering 3-month (Mascara), 12-month (Serum), and 24-month (Lipstick) scenarios.
- ✅ **Status Lifecycle**: Unit tests ensuring transitions between Unopened $\rightarrow$ Active $\rightarrow$ Expiring $\rightarrow$ Expired $\rightarrow$ Finished.
- ✅ **Financial Calculations**: Cost-per-day formulas and edge case handling (immediate finish 1-day safety).
- ✅ **Duplicate Detection**: Verification of brand/barcode collision prevention.

---

## 🛠️ Built With

- **[Flutter](https://flutter.dev)** - Cross-platform UI toolkit.
- **[Provider](https://pub.dev/packages/provider)** - State management.
- **[Mobile Scanner](https://pub.dev/packages/mobile_scanner)** - Real-time barcode & QR scanning.
- **[Flutter Local Notifications](https://pub.dev/packages/flutter_local_notifications)** - Expiry scheduling.
- **[FL Chart](https://pub.dev/packages/fl_chart)** - Category investment charts.
- **[Cloud Firestore & Firebase Auth](https://firebase.google.com)** - Cloud sync & user security.
- **[Open Beauty Facts](https://world.openbeautyfacts.org)** - Open cosmetic ingredient & barcode data.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
