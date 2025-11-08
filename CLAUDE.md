# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BetterBlue is a native iOS/watchOS app for controlling Hyundai and Kia vehicles via BlueLink/Kia Connect services. Built with SwiftUI, SwiftData, and powered by the [BetterBlueKit](https://github.com/schmidtwmark/BetterBlueKit) Swift package.

### BetterBlueKit Submodule

BetterBlueKit is included as a **git submodule** in the `BetterBlueKit/` directory. This allows local development and testing of BetterBlueKit changes without pushing to GitHub. The project is configured to use the local package via `XCLocalSwiftPackageReference`.

To initialize or update the submodule after cloning:
```bash
git submodule update --init --recursive
```

**Important**: The local submodule has the SwiftLint plugin commented out in `Package.swift` to avoid build conflicts with the main project. When pushing BetterBlueKit changes upstream, you may need to uncomment the plugin configuration in the standalone repository.

## Build Commands

### Building the Project
```bash
# Open in Xcode
open BetterBlue.xcodeproj

# Build for iOS simulator
xcodebuild -scheme BetterBlue -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Build for device
xcodebuild -scheme BetterBlue -destination 'generic/platform=iOS' build

# Build Watch app
xcodebuild -scheme "BetterBlueWatch Watch App" build

# Build Widget extension
xcodebuild -scheme WidgetExtension build
```

### Linting
SwiftLint has been removed from the project to avoid plugin conflicts when BetterBlueKit is used as a local package. You can run SwiftLint manually if needed:
```bash
swiftlint lint
```

## Architecture

### Multi-Target Structure
The project consists of four targets sharing a common SwiftData container:
- **BetterBlue** (Main iOS app)
- **BetterBlueWatch Watch App** (watchOS companion)
- **Widget** (iOS widgets, lock screen widgets, control center widgets, and Live Activities)
- **BetterBlueKit** (External Swift package for API communication)

### Data Persistence Layer

#### SwiftData Models
All models are in `BetterBlue/Models/`:
- `BBAccount.swift` - User accounts with credentials and brand/region
- `BBVehicle.swift` - Vehicle data with status, settings, and climate presets
- `HTTPLog.swift` - HTTP request/response logging
- `ClimatePreset.swift` - User-defined climate control presets

#### Shared Model Container
`SharedModelContainer.swift` provides the critical `createSharedModelContainer()` function:
- **Simulator**: Uses `/tmp/BetterBlue_Shared` to work around App Group isolation
- **Device**: Uses iCloud sync via `iCloud.com.markschmidt.BetterBlue` with App Group fallback (`group.com.betterblue.shared`)
- All targets must use this function to ensure data sharing

### API Client Architecture

#### Layered API Design (see `BetterBlue/Utility/`)
1. **BetterBlueKit Package** - Core API clients (Hyundai, Kia, Fake) implementing `APIClientProtocol`
2. **CachedAPIClient** (`CachedAPIClient.swift`) - Request deduplication and 5-second caching wrapper
3. **APIClientFactory** (`APIClientFactory.swift`) - Creates appropriate API client based on brand
4. **BBAccount Model** - SwiftData wrapper managing API client lifecycle, auth tokens, and command execution

#### Key Points
- API clients are `@Transient` (not persisted) and lazy-initialized on first use
- `CachedAPIClient` prevents duplicate simultaneous requests and caches responses
- Invalid session/credentials trigger automatic re-initialization via `handleInvalidVehicleSession()`
- Kia vehicles require `vehicleKey` field for commands (auto-fetched if missing)

### Status Change Waiting Pattern

`BBVehicle.waitForStatusChange()` implements an interruptible polling mechanism:
- Used after commands to wait for vehicle state changes (lock/unlock/climate)
- Polls status at intervals with configurable retry count
- Can be woken up early via `wakeUpStatusWaiters()` when status updates arrive
- Uses continuation-based async pattern with `StatusWaitingManager` actor

### App Intents & Widgets

`Widget/VehicleAppIntents.swift` provides Siri shortcuts, Control Center widgets, and app intents:
- **Lock/Unlock**: `LockVehicleIntent`, `UnlockVehicleIntent` with status waiting
- **Climate**: `StartClimateIntent`, `StopClimateIntent` (start uses selected climate preset)
- **Status**: `RefreshVehicleStatusIntent`, `GetVehicleStatusIntent`
- **Live Activities**: `VehicleLiveActivityManager` coordinates status updates during long-running operations

Control Center widgets use `ControlConfigurationIntent` for user-configured vehicle selection.

### Fake Vehicle Mode

Testing without real vehicles is supported via `Brand.fake`:
- `SwiftDataFakeVehicleProvider` (`BetterBlue/Utility/`) stores fake vehicle state in SwiftData
- `BBDebugConfiguration` struct enables simulating various failure modes
- Fake accounts automatically created for test credentials (see `APIClientFactory.isTestAccount()`)

## Key Concepts

### SwiftData Relationships
- `BBAccount` ←→ `BBVehicle`: One-to-many with cascade delete
- `BBVehicle` ←→ `ClimatePreset`: One-to-many with cascade delete
- Use `safeVehicles` and `safeClimatePresets` properties to safely unwrap optional relationships

### HTTP Logging
`HTTPLogSinkManager` singleton coordinates logging across all targets:
- Must be configured with `createSharedModelContainer()` and device type
- Creates `HTTPLogSink` instances for API clients to inject logs
- Logs viewable in Settings > HTTP Logs

### Distance & Temperature Units
`AppSettings` manages user preferences (stored in UserDefaults):
- `preferredDistanceUnit`: miles or kilometers
- `preferredTemperatureUnit`: Fahrenheit or Celsius
- Used throughout UI and in VehicleEntity for App Intents

### Account Initialization Pattern
Always initialize accounts before use:
```swift
try await account.initialize(modelContext: modelContext)
```
This ensures API client is created and login is performed.

### Vehicle Updates
`BBAccount.updateVehicles()` syncs fetched vehicles with SwiftData:
- Updates existing vehicles while preserving UI state (custom names, colors, sort order)
- Creates new vehicles with auto-incrementing sort order
- Removes vehicles no longer returned by API

## Common Workflows

### Adding a New Vehicle Command
1. Add to `VehicleCommand` enum in BetterBlueKit
2. Implement in BetterBlueKit API clients (Hyundai/Kia/Fake)
3. Add convenience method in `BBAccount` extensions (see `lockVehicle()`, etc.)
4. Create App Intent in `VehicleAppIntents.swift` if needed
5. Update fake vehicle provider in `SwiftDataFakeVehicleProvider.executeCommand()`

### Creating a New Widget
1. Create widget view conforming to `Widget` protocol in `Widget/`
2. Register in `BetterBlueWidgetBundle.swift`
3. Use `createSharedModelContainer()` in timeline provider
4. Query `BBVehicle` with proper predicates for filtering

### Debugging Data Sync Issues
- Check device type detection in `HTTPLogSinkManager.detectMainAppDeviceType()`
- Verify App Group container is accessible: look for "App Group container not accessible" warnings
- On simulator, check `/tmp/BetterBlue_Shared/BetterBlue.sqlite`
- Use Diagnostics view (Settings > About) to inspect iCloud sync status

## File Organization

- `BetterBlue/Views/` - SwiftUI views for main app
- `BetterBlue/Views/Components/` - Reusable view components
- `BetterBlue/Models/` - SwiftData models
- `BetterBlue/Utility/` - Helper classes and utilities
- `BetterBlueWatch Watch App/` - watchOS app files
- `Widget/` - Widget extensions, App Intents, and Live Activities

## Important Conventions

- All API operations must pass `modelContext: ModelContext` parameter
- Use `@MainActor` for SwiftData operations and API client methods
- Vehicle commands should use status waiting pattern where state verification is needed
- Climate presets: selected preset takes precedence, fallback to first preset, then default options
- VIN is the primary identifier for vehicles across all operations
