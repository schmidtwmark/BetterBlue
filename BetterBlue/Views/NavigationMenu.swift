//
//  NavigationMenu.swift
//  BetterBlue
//
//  Navigation utilities for launching different mapping applications
//

import BetterBlueKit
import CoreLocation
import SwiftUI
import UIKit

enum MapApp: String, CaseIterable {
    case appleMaps = "Apple Maps"
    case googleMaps = "Google Maps"
    case waze = "Waze"

    var urlScheme: String {
        switch self {
        case .appleMaps:
            "maps://"
        case .googleMaps:
            "comgooglemaps://"
        case .waze:
            "waze://" // Keep original for app detection
        }
    }

    var appStoreURL: String {
        switch self {
        case .appleMaps:
            "" // Apple Maps is built-in
        case .googleMaps:
            "https://apps.apple.com/app/google-maps/id585027354"
        case .waze:
            "https://apps.apple.com/app/waze-navigation-live-traffic/id323229106"
        }
    }

    var systemIcon: String {
        switch self {
        case .appleMaps:
            "map"
        case .googleMaps:
            "globe"
        case .waze:
            "car.2"
        }
    }

    func navigationURL(to coordinate: CLLocationCoordinate2D, destinationName: String? = nil) -> URL? {
        switch self {
        case .appleMaps:
            var components = URLComponents()
            components.scheme = "maps"
            components.queryItems = [
                URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)")
            ]
            if let name = destinationName {
                components.queryItems?.append(URLQueryItem(name: "q", value: name))
            }
            return components.url

        case .googleMaps:
            // Google Maps universal link for directions
            let googleMapsURLString = "https://maps.google.com/?daddr=\(coordinate.latitude)," +
                "\(coordinate.longitude)&directionsmode=driving"
            return URL(string: googleMapsURLString)

        case .waze:
            // Waze universal link
            let wazeURLString = "https://waze.com/ul?ll=\(coordinate.latitude),\(coordinate.longitude)"
            return URL(string: wazeURLString)
        }
    }
}

enum NavigationHelper {
    /// Get all available map apps installed on the device
    static var availableMapApps: [MapApp] {
        MapApp.allCases
    }

    /// Navigate to a coordinate using the specified map app
    /// - Parameters:
    ///   - app: The map app to use
    ///   - coordinate: The destination coordinate
    ///   - destinationName: Optional name for the destination
    @MainActor static func navigate(
        using app: MapApp,
        to coordinate: CLLocationCoordinate2D,
        destinationName: String? = nil,
    ) {
        guard let url = app.navigationURL(to: coordinate, destinationName: destinationName) else {
            BBLogger.error(.app, "NavigationHelper: Could not create URL for \(app.rawValue)")
            return
        }

        BBLogger.debug(.app, "NavigationHelper: Opening \(app.rawValue) with URL: \(url.absoluteString)")

        UIApplication.shared.open(url) { success in
            if success {
                BBLogger.info(.app, "NavigationHelper: Successfully opened \(app.rawValue)")
            } else {
                BBLogger.error(.app, "NavigationHelper: Failed to open \(app.rawValue) with URL: \(url.absoluteString)")

                // If the app failed to open and it's not Apple Maps, try to open in Apple Maps as fallback
                if app != .appleMaps {
                    BBLogger.info(.app, "NavigationHelper: Falling back to Apple Maps...")
                    if let appleUrl = MapApp.appleMaps.navigationURL(to: coordinate, destinationName: destinationName) {
                        UIApplication.shared.open(appleUrl)
                    }
                }
            }
        }
    }

    /// Show action sheet to choose which map app to use for navigation
    /// - Parameters:
    ///   - coordinate: The destination coordinate
    ///   - destinationName: Optional name for the destination
    ///   - presentingViewController: The view controller to present the action sheet from
    @MainActor static func showNavigationOptions(to coordinate: CLLocationCoordinate2D,
                                                 destinationName: String? = nil,
                                                 from presentingViewController: UIViewController) {
        let availableApps = availableMapApps

        guard !availableApps.isEmpty else {
            let alert = UIAlertController(
                title: "No Map Apps",
                message: "No supported map applications are installed on this device.",
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presentingViewController.present(alert, animated: true)
            return
        }

        let actionSheet = UIAlertController(
            title: "Navigate to Vehicle",
            message: "Choose which app to use for navigation",
            preferredStyle: .actionSheet,
        )

        for app in availableApps {
            let action = UIAlertAction(title: app.rawValue, style: .default) { _ in
                navigate(using: app, to: coordinate, destinationName: destinationName)
            }
            actionSheet.addAction(action)
        }

        actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // For iPad
        if let popover = actionSheet.popoverPresentationController {
            popover.sourceView = presentingViewController.view
            popover.sourceRect = CGRect(
                x: presentingViewController.view.bounds.midX,
                y: presentingViewController.view.bounds.midY,
                width: 0,
                height: 0,
            )
            popover.permittedArrowDirections = []
        }

        presentingViewController.present(actionSheet, animated: true)
    }
}

// SwiftUI wrapper for navigation functionality
struct NavigationMenuContent: View {
    let coordinate: CLLocationCoordinate2D
    let destinationName: String?

    var body: some View {
        let availableApps = NavigationHelper.availableMapApps

        if availableApps.isEmpty {
            Text("No map apps available")
                .foregroundColor(.secondary)
        } else {
            ForEach(availableApps, id: \.rawValue) { app in
                Button {
                    NavigationHelper.navigate(using: app, to: coordinate, destinationName: destinationName)
                } label: {
                    Label(app.rawValue, systemImage: app.systemIcon)
                }
            }
        }
    }
}
