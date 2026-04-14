# Convergent Scanner 📷🚘

A high-performance, cross-platform (Web & Mobile) License Plate Recognition (LPR) application built with Flutter. Convergent Scanner utilizes real-time camera streams and a multi-tiered OCR pipeline to instantly extract plate numbers and conduction stickers, validating vehicles against a centralized Firebase database. 

## Features
* **Dual-Tier Scanning Pipeline:**
    * **Auto-Scan (Mobile):** High-speed edge inference using Google ML Kit. Employs a dynamic "Largest-Font Priority" engine to aggressively filter background noise and instantly snap to prominent license plates at 30 FPS.
    * **Manual Capture (Web & Mobile):** Cloud-assisted pipeline using Roboflow for precise plate detection & cropping, paired with Plate Recognizer API for 99% accuracy on challenging plates.
* **Intelligent Auto-Correction:** Region-aware OCR correction and database fuzzy-matching to seamlessly handle 0/O, 1/I, and 8/B character ambiguities.
* **Instant Cloud Sync:** Real-time database queries against Firebase Cloud Firestore for instantaneous vehicle validation.

---

## 🛠 Setup Instructions

### Prerequisites
Before you begin, ensure you have the following installed:
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest stable release)
* [Dart SDK](https://dart.dev/get-dart)
* [Android Studio](https://developer.android.com/studio) (for Android builds) or Xcode (for iOS builds)
* Google Chrome (for Web debugging)
* A Firebase Project with Cloud Firestore database enabled (`google-services.json` / `GoogleService-Info.plist` configured).

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/convergent-scanner.git
   cd convergent-scanner
   ```

2. **Install Flutter Dependencies:**
   ```bash
   flutter pub get
   ```

3. **Configure API Keys:**
   * Open `lib/services/plate_recognizer_service.dart` and insert your Plate Recognizer API Token.
   * Open `lib/services/roboflow_service.dart` and insert your Roboflow API Key.
   * Ensure your Firebase configuration files are placed in their respective `android/app` and `ios/Runner` directories.

### Running the App

To run the application locally on a connected mobile device or emulator:
```bash
flutter run
```

To run the optimized Web Application on Chrome:
```bash
flutter run -d chrome --web-renderer auto
```

---

## 💻 Technologies Used

### Core Framework
* **Flutter** - Cross-platform UI framework.
* **Dart** - Primary programming language.

### Backend & Cloud
* **Firebase Cloud Firestore** - NoSQL database for real-time vehicle validation records.

### AI & Computer Vision Stack
* **Google ML Kit (Vision)** - On-device edge OCR for real-time Auto-Scan loop on mobile.
* **Roboflow** - Object detection API to locate and isolate plates in full camera frames.
* **Plate Recognizer LPR API** - Dedicated ANPR/ALPR engine for maximum accuracy fallback.
* **Tesseract.js** - Browser-based WebAssembly OCR for the Web Scanner.
* **image (Dart package)** - Used for programmatic EXIF rotation correction and inline Isolate frame cropping.

---

## 📂 Project Structure

```text
lib/
 ├── main.dart                             # Application entry point & theme configuration
 ├── models/                               
 │    └── vehicle_model.dart               # Data structures mapped to Firestore documents
 ├── screens/                              
 │    ├── admin_dashboard.dart             # Admin panel for uploading vehicle records/Excel sheets
 │    ├── camera_scanner_screen.dart       # Mobile Live-Camera UI and Auto-Scan Pipeline
 │    └── camera_scanner_screen_web.dart   # Web-optimized Camera UI and Tesseract integrations
 ├── services/                             
 │    ├── firestore_service.dart           # Database connectivity logic
 │    ├── plate_recognizer_service.dart    # Plate Recognizer API JSON parsing
 │    └── roboflow_service.dart            # Roboflow object detection & API logic
 └── widgets/                              
      └── vehicle_result_popup.dart        # Reusable bottom-sheet UI for scan results
```

---

## 🚀 Example Usage

### 1. Auto-Scan (Mobile)
Simply point the camera frame at a license plate.
* **Expected Output:** The AI engine will instantly ignore the dealer-frame text, highlight the main plate, and pop up the vehicle verification sheet confirming authorization automatically.

### 2. Manual Scan (Web)
Point your mobile or laptop webcam at an approaching vehicle and tap the floating  Capture & Scan Action Button.
* **Expected Output:**
  ```text
  Status: Capturing... 
  Status: AI locating plate...
  Status: AI scanning zoomed crop...
  ```
  The Result Bottom Sheet will slide up on-screen displaying `No record found.` if the plate is not registered in the system.

---

## 🗺 Roadmap

- [ ] **Offline Mode:** Implement local SQLite caching for the vehicle database to allow scanning in dead zones.
- [ ] **Data Export:** Add CSV/Excel export functionality directly from the Admin Dashboard for daily scan logs.
- [ ] **Multi-plate Detection:** Support scanning multiple license plates simultaneously in a crowded parking lot.
- [ ] **Analytics Dashboard:** Build graphical UI visualizations in the Admin panel to track vehicle entry/exit frequencies.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
