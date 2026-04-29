//
//  Notifications.swift
//  BetterBlue
//
//  Cross-platform notification names. Shared between iOS app, macOS app,
//  watch app, widget extensions — anywhere that needs to post or listen
//  for these well-known names.
//

import Foundation

extension Notification.Name {
    static let fakeAccountConfigurationChanged = Notification.Name("FakeAccountConfigurationChanged")
    static let selectVehicle = Notification.Name("SelectVehicle")
}
