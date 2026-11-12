# Nocturne for Android

The Android version of Nocturne: private chats with the people on your Nocturne server, video calls, and push
notifications through Firebase. Kotlin + Jetpack Compose, Android 8.0 and up (made for a Galaxy Note 8 on Android 9).

## Signing in
Each person signs in with their **join link** from the Nocturne server (`nocturne-server adduser ...` prints it).
Opening it on the phone shows a page with the app download and an **Open Nocturne and sign in** button
(`nocturne://setup?server=…&token=…`). Someone with one conversation goes straight into it; someone with several
gets a list.

## Build
Needs JDK 17+ and the Android SDK (platform 34, build-tools 34).
```sh
echo "sdk.dir=/path/to/android-sdk" > local.properties
./gradlew assembleRelease          # -> app/build/outputs/apk/release/app-release.apk
```
- **Push:** put `google-services.json` (Firebase console → Android app `com.ross.nocturne`) in `app/`. Without it
  the app still works but only fetches messages while it's open.
- **Signing:** `signing/signing.properties` + `signing/nocturne-release.jks`. They live only in the private build
  repo; this public repo ignores them. Keep the key forever: Android only installs an update signed with the same
  key. Without it the build falls back to a debug key, which can't update an installed copy.

## Install on the phone
Copy the APK to the server as `/data/nocturne.apk` (it's served at `/app/nocturne.apk` and linked from the join
page), or set the server's `APK_URL`. On the phone, allow the browser to install apps when asked.
