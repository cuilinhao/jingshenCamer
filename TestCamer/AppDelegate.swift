//
//  AppDelegate.swift
//  TestCamer
//
//  Created by Linhao-Mac on 2026/9/21.
//

import UIKit

@main
@MainActor
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let hardware = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        TestLog.shared.record("launch revision=depth-quality-TestLog-2026-09-22, version=\(info["CFBundleShortVersionString"] ?? "unknown"), build=\(info["CFBundleVersion"] ?? "unknown"), hardware=\(hardware), system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", category: "app")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TestLog.shared.record("application will terminate", category: "app")
        TestLog.shared.flush()
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

