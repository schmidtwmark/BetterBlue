//
//  Date.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import Foundation

func formatLastUpdated(_ date: Date?) -> String {
    guard let date else {
        return ""
    }
    let calendar = Calendar.current
    let timeFormatter = DateFormatter()
    timeFormatter.timeStyle = .short

    if calendar.isDateInToday(date) {
        return "Today at \(timeFormatter.string(from: date))"
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday at \(timeFormatter.string(from: date))"
    } else {
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .short
        return dayFormatter.string(from: date)
    }
}

func compactLastUpdated(_ date: Date?) -> String {
    guard let date else {
        return ""
    }

    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    } else {
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .none
        return dayFormatter.string(from: date)
    }
}
