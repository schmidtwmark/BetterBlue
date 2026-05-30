# BetterBlue React Native Setup

## Prerequisites

- Node.js 18+
- npm or yarn
- Expo CLI: `npm install -g expo-cli`
- iOS: Xcode + iOS Simulator (macOS only)
- Android: Android Studio + Android Emulator

## Install Dependencies

```bash
cd BetterBlueRN
npm install
```

## Start Development Server

```bash
npx expo start
```

> **Note:** Expo Go will NOT work because this project uses custom native modules (expo-secure-store, expo-notifications, react-native-maps). You must use a development build.

## Create Development Build

### iOS (macOS only)
```bash
npx expo run:ios
```

### Android
```bash
npx expo run:android
```

## About the API

BetterBlue uses the unofficial Hyundai BlueLink and Kia Connect APIs. These are not officially documented and may change at any time. The implementations are based on the open-source [bluelinky](https://github.com/Hacksore/bluelinky) project and the [hyundai_kia_connect_api](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api) Python library.

## Test Accounts

Use a username starting with `fake@` or `test@` to activate fake vehicle mode. No real API calls are made and any password works.

- Username: `fake@test.com`
- Password: `anything`
- PIN: `1234`

## Architecture Notes

- API clients: `src/api/`
- State management: Zustand (`src/store/`)
- Navigation: Expo Router (file-based routing in `app/`)
- Styling: NativeWind v4 (Tailwind CSS for React Native)
- Secure credentials: expo-secure-store
- Local data cache: expo-sqlite
