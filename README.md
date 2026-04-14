# Finapp (local run)

## Prerequisites

- PostgreSQL running locally
- Node.js 18+ (project targets Node 22)
- Flutter 3.41+ / Dart 3.11+

## Database

1. Create a database (e.g. `finapp`).
2. Apply the schema:

```bash
psql "$DATABASE_URL" -f backend/data_model/postgres_schema.sql
```

## Backend

```bash
cd backend
cp .env.example .env
# Set DATABASE_URL and STATIC_OTP in .env
npm install
npm run dev
```

API listens on `http://localhost:3000` by default.

## Exposing the API with ngrok

Use this when the app runs on a **physical phone** or any network without your machine’s LAN IP.

1. Start the backend (`npm run dev` in `backend/`).
2. In another terminal:

```bash
ngrok http 3000
```

3. Copy the **HTTPS** forwarding URL (e.g. `https://abcd-1234.ngrok-free.app`). Keep ngrok running while you use the app.
4. Point Flutter at that base URL (no trailing slash):

```bash
cd frontend_flutter
flutter run --dart-define=API_BASE=https://your-subdomain.ngrok-free.app
```

For a release APK, use the same `--dart-define` on `flutter build apk` or `flutter build appbundle`.

`CORS_ORIGIN=*` in `.env` is fine for API clients from the app. The tunnel is HTTPS, so you do not need cleartext HTTP exceptions for that URL.

## Flutter (local only)

Use `127.0.0.1` for iOS simulator / desktop / Chrome. For **Android emulator**, use `http://10.0.2.2:3000`.

```bash
cd frontend_flutter
flutter pub get
flutter run --dart-define=API_BASE=http://127.0.0.1:3000
```

Log in with any email and the OTP from `STATIC_OTP` in the backend `.env`.

## Install on an Android phone (release APK)

The API base URL is **fixed at build time**. Use your real backend URL (ngrok HTTPS, or your PC’s LAN IP if the phone is on the same Wi‑Fi).

1. **On your computer** — install [Android Studio](https://developer.android.com/studio) (recent versions include a **JDK 17** runtime) or the [Android SDK](https://developer.android.com/tools) so `flutter` can build APKs. **Gradle needs Java 17** to run (not only to compile). Enable **USB debugging** on the phone if you will use a USB cable (`Settings → Developer options`).

2. **Build a release APK** (replace the URL with yours, no trailing slash):

```bash
cd frontend_flutter
flutter pub get
flutter build apk --release --dart-define=API_BASE=https://your-subdomain.ngrok-free.app
```

Output file:

`frontend_flutter/build/app/outputs/flutter-apk/app-release.apk`

3. **Put the APK on the phone**, then install:

   - **USB + ADB** (phone unlocked, cable connected, authorize the computer when prompted):

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

   - **No USB** — copy `app-release.apk` (AirDrop, Google Drive, email attachment, USB stick, etc.), open it in **Files** on the phone, and tap to install. You may need **Settings → Security** (or per-app settings) to allow **Install unknown apps** for **Files** or **Chrome**.

4. **Run the app** — ensure the backend is reachable at the URL you baked in (ngrok running, or PC on and API listening). If your tunnel URL changes, **rebuild** the APK with the new `--dart-define=API_BASE=...`.

Optional: run on a device over USB without installing permanently:

```bash
flutter run --release --dart-define=API_BASE=https://your-subdomain.ngrok-free.app
```

### Android build fails: “requires Java 17” / you are using Java 11

The **Android Gradle Plugin** runs on the JVM that Gradle uses. If that JVM is **11** (common with older Android Studio paths like `.../Android Studio.app/Contents/jre/...`), the build fails even though the project targets Java 17.

**Fix (pick one):**

1. **Point Flutter at JDK 17** (after installing a JDK 17, e.g. from [Adoptium](https://adoptium.net) or `brew install openjdk@17` on macOS):

```bash
/usr/libexec/java_home -V    # list installed JDKs; pick 17
flutter config --jdk-dir "$(/usr/libexec/java_home -v 17)"
flutter doctor --verbose     # confirm Java toolchain
```

2. **Homebrew OpenJDK 17** (Apple Silicon example path; adjust if yours differs):

```bash
flutter config --jdk-dir "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
```

3. **Newer Android Studio JBR** — often at  
   `/Applications/Android Studio.app/Contents/jbr/Contents/Home`  
   (not the old `Contents/jre/...` path). If that folder exists:

```bash
flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

4. **Gradle only** — in `frontend_flutter/android/gradle.properties` you can set `org.gradle.java.home=/absolute/path/to/jdk17` (see commented template in that file).

Then run `flutter build apk ...` again from `frontend_flutter`.
