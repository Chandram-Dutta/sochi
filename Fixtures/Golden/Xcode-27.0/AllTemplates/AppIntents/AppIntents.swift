//
//  AppIntents.swift
//  AppIntents
//
//  Created by Chandram Dutta on 11/10/26.
//

import AppIntents

struct AppIntents: AppIntent {
    static var title: LocalizedStringResource { "AppIntents" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
